import os
from pynq import Overlay
from pynq import allocate
import xrfclk
import numpy as np
import matplotlib.pyplot as plt
from axitimer import AxiTimerDriver
from axitxfifo import AxiStreamFifoDriver
import scipy.signal
import scipy.io
import time
import serial

class DDSOverlay(Overlay):
    def __init__(self, bitfile_name=None, dbg=False, plot=False, n_buffers=1, phase_calibration=True, **kwargs):
        if bitfile_name is None:
            this_dir = os.path.dirname(__file__)
            bitfile_name = os.path.join(this_dir, 'hw', 'top.bit')
        if dbg:
            print(f'loading bitfile {bitfile_name}')
        super().__init__(bitfile_name, **kwargs)
        # get IPs
        self.dma_recv = self.axi_dma_0.recvchannel
        self.capture_trig = self.axi_gpio_capture.channel1[0]
        self.trigger_mode = self.axi_gpio_trigger_sel.channel1[0]
        self.adc_select = self.axi_gpio_adc_sel.channel1[0]
        self.pinc = self.axi_fifo_pinc
        self.cos_scale = self.axi_fifo_scale
        self.timer = self.axi_timer_0
        self.lmh6401 = self.axi_fifo_lmh6401
        
        xrfclk.set_ref_clks(lmk_freq=122.88, lmx_freq=409.6)
        
        self.f_samp = 4.096e9 # Hz
        self.phase_bits = 24
        self.timer.start_tmr()
        self.dma_frame_shape = (32*32768, 2)
        self.dma_frame_size = self.dma_frame_shape[0]*self.dma_frame_shape[1]
        alloc_bytes = n_buffers * self.dma_frame_size * 2 
        if (alloc_bytes > 3e9):
            raise ValueError(f"refusing to allocate {round(alloc_bytes/(2**20))}MiB of DMA buffer, try again with smaller n_buffers")
        self.dma_buffers = [allocate(shape=self.dma_frame_shape, dtype=np.int16) for i in range(n_buffers)]
        self.dbg = dbg
        self.plot = plot
        self.t_sleep = 0.005
        # need sleeps around AXI transactions, or data isn't captured correctly
        # i.e. there are frequency changes in data that is manually triggered
        # (which should not have frequency changes)
        # having a single AXI-slave device with multiple registers instead of
        # separate AXI GPIOs should prevent issues arising from transaction reordering

    def measure_phase(self, tones, OSR1=4, OSR2=1024):
        n_intersect = self._coarse_delay_n(tones)
        fine_delay_n_crossover = self._fine_delay_n_crossover(tones, n_intersect, OSR1)
        fine_delay_n_corrected = self._fine_delay_n_correction(tones, fine_delay_n_crossover, OSR1, OSR2)
        # resample final 3 periods of test tone
        N_samp = round(7*self.f_samp/tones[1])
        test = np.zeros((N_samp, 2))
        test[:,0] = -1*self.dma_buffers[0][-N_samp:,0]
        test[:,1] = self.dma_buffers[0][-N_samp-(fine_delay_n_corrected//OSR2):-(fine_delay_n_corrected//OSR2),1]
        test_upsampled = scipy.signal.resample_poly(test,OSR2,1,axis=0)
        if self.plot:
            plt.figure()
            plt.plot(np.arange(0,N_samp), test, '.')
            plt.plot(np.arange(0,N_samp*OSR2)/OSR2, test_upsampled, '-')
        # get phase using covariance method with middle samples
        N_samp = round(2*self.f_samp/tones[1]*OSR2)
        sectioned = test_upsampled[len(test_upsampled)//2-N_samp:len(test_upsampled)//2+N_samp,:]
        cov = np.cov(np.transpose((sectioned - np.mean(sectioned, axis=0))/np.std(sectioned, axis=0)))
        phi = np.arccos(np.clip(cov[0,1],-1,1))
        if self.dbg:
            print(f'phi = {phi} ({phi*180/np.pi} deg)')
        return phi

    def _coarse_delay_n(self, tones):
        if self.dbg:
            print(f'measuring phase delay of frequency {round(tones[1]/1e6)}MHz with reference {round(tones[0]/1e6)}MHz')
        # get coarse phase delay with spectrogram
        self.set_vga_atten_dB(18)
        self.set_dac_atten_dB(12)
        self.set_adc_source('afe')
        self.set_sample_buffer_trigger_source('manual')
        self.set_freq_hz(tones[0])
        self.set_sample_buffer_trigger_source('dds_auto')
        self.set_freq_hz(tones[1])
        self.dma(0)
        # only need first 4096 samples
        raw = self.dma_buffers[0][:4096,:]*[-1, 1]
        # these parameters seem to give good results
        N_fft = 64
        N_overlap = 32
        f, t, Sxx = scipy.signal.spectrogram(raw, self.f_samp, axis=0, nfft=N_fft, nperseg=N_fft, noverlap=N_overlap)
        # plot raw data and spectrogram
        if self.plot:
            plt.figure()
            plt.plot((raw - np.mean(raw, axis=0))/np.std(raw, axis=0) + [0, 4], '.')
            fig, ax = plt.subplots(2,1)
            ax[0].plot(raw[:,1], '.')
            ax[0].set_xlim([1350, 1450])
            ax[1].plot(raw[:,0], '.')
            ax[1].set_xlim([2050, 2150])
            plt.figure()
            plt.pcolormesh(t, f, Sxx[:,0,:], shading='nearest')
            plt.colorbar()
            plt.ylim([0,200e6])
        # get overlap location in time
        bin_idx = np.zeros(2, dtype=np.uint16)
        for i in range(2):
            bin_idx[i] = (np.abs(f - tones[i])).argmin()
        plt.figure()
        plt.plot(t, np.transpose(Sxx[bin_idx,0,:]), '.')
        plt.plot(t, np.transpose(Sxx[bin_idx,1,:]), '.')
        n_intersect = np.zeros(2)
        for i in range(2):
            S_lo_last = Sxx[bin_idx[0],i,0]
            S_hi_last = Sxx[bin_idx[1],i,0]
            for t_idx in range(1,len(t)):
                S_lo = Sxx[bin_idx[0],i,t_idx]
                S_hi = Sxx[bin_idx[1],i,t_idx]
                if S_hi > S_lo:
                    n_intersect[i] = t[t_idx]*self.f_samp + (S_hi - S_lo)/(S_lo - S_lo_last + S_hi_last - S_hi)
                    S_lo_last = S_lo
                    S_hi_last = S_hi
                    break
        if self.dbg:
            coarse_delay_n = n_intersect[0] - n_intersect[1]
            print(f'n_intersect = {n_intersect}')
            print(f't_intersect = {n_intersect/self.f_samp}')
            print(f'coarse_delay_n = {coarse_delay_n}')
        return n_intersect

    def _fine_delay_n_crossover(self, tones, n_intersect, OSR):
        # get fine delay by oversampling and measuring cross-correlation of reference/alignment tone
        n_min = round((n_intersect[0] - 2*self.f_samp/tones[0])*OSR)
        n_max = round((n_intersect[0] + 2*self.f_samp/tones[0])*OSR)
        upsampled = scipy.signal.resample_poly(np.array(self.dma_buffers[0][:4096,:],dtype=np.float32),OSR,1,axis=0)*[-1,1]
        xcorr = scipy.signal.correlate(upsampled[n_min:n_max,0], upsampled[:4096*OSR,1])
        lags = scipy.signal.correlation_lags(n_max-n_min,4096*OSR)
        fine_delay_n_crossover = lags[np.argmax(xcorr)] + n_min
        if self.plot:
            fig, ax = plt.subplots(2,1)
            ax[0].plot(lags/OSR + n_min/OSR, xcorr)
            ax[1].plot(lags/OSR + n_min/OSR, xcorr)
            coarse_delay_n = n_intersect[0] - n_intersect[1]
            ax[1].set_xlim([coarse_delay_n - 100, coarse_delay_n + 100])
        if self.dbg:
            print(f'fine_delay_n_crossover = {fine_delay_n_crossover} = {fine_delay_n_crossover/OSR}*{OSR}')
        return fine_delay_n_crossover

    def _fine_delay_n_correction(self, tones, fine_delay_n_crossover, OSR1, OSR2):
        # first shift by fine_delay_n_crossover//OSR1, then resample 3 periods of the reference tone at OSR2 >> OSR1
        N_samp = round(3*self.f_samp/tones[0])
        reference = np.zeros((N_samp, 2))
        reference[:,0] = -1*self.dma_buffers[0][fine_delay_n_crossover//OSR1:fine_delay_n_crossover//OSR1+N_samp,0]
        reference[:,1] = self.dma_buffers[0][:N_samp,1]
        reference_upsampled = scipy.signal.resample_poly(reference,OSR2,1,axis=0)
        xcorr = scipy.signal.correlate(reference_upsampled[:,0], reference_upsampled[:,1])
        lags = scipy.signal.correlation_lags(N_samp*OSR2, N_samp*OSR2)
        fine_delay_n_correction = round(fine_delay_n_crossover*OSR2/OSR1) + lags[np.argmax(xcorr)]
        if self.plot:
            plt.figure()
            plt.plot(np.arange(0,N_samp), reference, '.')
            plt.plot(np.arange(0,N_samp*OSR2)/OSR2, reference_upsampled, '-')
            plt.figure()
            plt.plot(lags/OSR2, xcorr)
        if self.dbg:
            print(f'fine_delay_n_correction = {fine_delay_n_correction} = {fine_delay_n_correction/OSR2}*{OSR2}')
        return fine_delay_n_correction

    def set_freq_hz(self, freq_hz):
        pinc = int((freq_hz/self.f_samp)*(2**self.phase_bits))
        if self.dbg:
            print(f'setting pinc to {pinc} ({freq_hz:.3e}Hz)')
        self.pinc.send_tx_pkt([pinc])
        time.sleep(self.t_sleep)

    def set_dac_atten_dB(self, atten_dB):
        scale = round(atten_dB/6)
        if scale < 0 or scale > 15:
            raise ValueError("cannot set attenuation less than 0dB or more than 90dB")
        if self.dbg:
            print(f'setting cos_scale to {scale} ({6*scale}dB attenuation)')
        self.cos_scale.send_tx_pkt([scale])
        time.sleep(self.t_sleep)

    def set_vga_atten_dB(self, atten_dB):
        atten_dB = round(atten_dB)
        if atten_dB < 0 or atten_dB > 32:
            raise ValueError("atten_dB out of range, pick a number between 0 and 32dB")
        packet = 0x0200 | atten_dB & 0x3f # address 0x02, 6-bit data atten_dB
        if self.dbg:
            print(f'setting vga attenuation to {atten_dB}dB')
        self.lmh6401.send_tx_pkt([packet])
        time.sleep(self.t_sleep)

    def set_adc_source(self, adc_source):
        if adc_source == 'afe':
            self.adc_select.off()
        elif adc_source == 'balun':
            self.adc_select.on()
        else:
            raise ValueError(f"invalid choice of adc_source: {adc_source}, please choose one of 'afe' or 'balun'")
        time.sleep(self.t_sleep)

    def set_sample_buffer_trigger_source(self, trig_source):
        if trig_source == 'dds_auto':
            self.trigger_mode.on()
        elif trig_source == 'manual':
            self.trigger_mode.off()
        else:
            raise ValueError(f"invalid choice of trig_source: {trig_source}, please choose one of 'dds_auto' or 'manual'")
        time.sleep(self.t_sleep)

    def manual_trigger(self):
        self.capture_trig.on()
        self.capture_trig.off()
        time.sleep(self.t_sleep)

    def dma(self, buffer_idx):
        time.sleep(self.t_sleep)
        self.dma_recv.transfer(self.dma_buffers[buffer_idx])
        time.sleep(self.t_sleep)
    
    def realloc_buffers(self, n_buffers):
        if len(self.dma_buffers) == n_buffers:
            return
        alloc_bytes = n_buffers * self.dma_frame_size * 2 
        if (alloc_bytes > 1e9):
            raise ValueError(f"refusing to allocate {round(alloc_bytes/(2**20))}MiB of DMA buffer, try again with smaller n_buffers")
        del self.dma_buffers
        self.dma_buffers = [allocate(shape=self.dma_frame_shape, dtype=np.int16) for i in range(n_buffers)]

    def capture_data(self, buffer, N_samp=128, OSR=256):
        t1 = self.timer.read_count()
        self.dma_recv.transfer(buffer)
        t2 = self.timer.read_count()
        time.sleep(0.01)
        if self.dbg:
            dt = self.timer.time_it(t1, t2)
            MiB = round(self.dma_frame_size*2/(2**20), 3)
            rate = round(self.dma_frame_size/(1e9)/dt, 3)
            print(f"transferred {MiB}MiB in {round(dt*1e6)}us ({rate}GS/s)")
        if self.plot:
            tvec = np.linspace(0,N_samp/self.f_samp*1e9,N_samp,endpoint=False)
            tvec_osr = np.linspace(0,N_samp/self.f_samp*1e9,N_samp*OSR,endpoint=False)
            plt.figure()
            plt.plot(tvec,buffer[N_samp:2*N_samp,0], '.')
            plt.plot(tvec_osr,scipy.signal.resample_poly(np.array(buffer[:8*N_samp,0],dtype=np.float32),OSR,1)[N_samp*OSR:2*N_samp*OSR], '-')
            plt.plot(tvec,buffer[N_samp:2*N_samp,1], '.')
            plt.plot(tvec_osr,scipy.signal.resample_poly(np.array(buffer[:8*N_samp,1],dtype=np.float32),OSR,1)[N_samp*OSR:2*N_samp*OSR], '-')

    def do_freq_sweep(self, name, dac_atten_dB, vga_atten_dB, freqs):
        self.set_dac_atten_dB(dac_atten_dB)
        self.set_vga_atten_dB(vga_atten_dB)
        self.realloc_buffers(len(freqs))
        for i,freq in enumerate(freqs):
            self.set_freq_hz(freq)
            self.capture_data(self.dma_buffers[i])
        scipy.io.savemat(name, {"tdata": np.array(self.dma_buffers), "freqs_hz": np.array(freqs), "dma_shape": self.dma_frame_shape, "dac_atten_dB": dac_atten_dB})
