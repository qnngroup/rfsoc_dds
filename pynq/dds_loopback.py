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
        if dbg:
            print('loaded bitstream')
            time.sleep(0.5)
        # get IPs
        self.dma_recv = self.axi_dma_0.recvchannel
        self.capture_trig = self.axi_gpio_capture.channel1[0]
        self.trigger_mode = self.axi_gpio_trigger_sel.channel1[0]
        self.adc_select = self.axi_gpio_adc_sel.channel1[0]
        self.pinc = [self.dds_hier_0.axi_fifo_pinc_0, self.dds_hier_1.axi_fifo_pinc_1]
        self.cos_scale = [self.dds_hier_0.axi_fifo_scale_0, self.dds_hier_1.axi_fifo_scale_1]
        self.timer = self.axi_timer_0
        self.lmh6401 = self.lmh6401_hier.axi_fifo_lmh6401
        
        xrfclk.set_ref_clks(lmk_freq=122.88, lmx_freq=409.6)
        if dbg:
            print('set clocks')
        
        self.f_samp = 4.096e9 # Hz
        self.phase_bits = 24
        self.timer.start_tmr()
        self.dma_frame_shape = (32*32768,)
        self.dma_frame_size = 32*32768#self.dma_frame_shape[0]*self.dma_frame_shape[1]
        alloc_bytes = n_buffers * self.dma_frame_size * 2 
        if (alloc_bytes > 3e9):
            raise ValueError(f"refusing to allocate {round(alloc_bytes/(2**20))}MiB of DMA buffer, try again with smaller n_buffers")
        self.dma_buffers = [allocate(shape=self.dma_frame_shape, dtype=np.int16) for i in range(n_buffers)]
        self.dbg = dbg
        self.plot = plot
        self.t_sleep = 0.008
        # need sleeps around AXI transactions, or data isn't captured correctly
        # i.e. there are frequency changes in data that is manually triggered
        # (which should not have frequency changes)
        # having a single AXI-slave device with multiple registers instead of
        # separate AXI GPIOs should prevent issues arising from transaction reordering
    
    def shutdown_dac(self):
        self.set_dac_atten_dB(90,0)
        self.set_dac_atten_dB(90,1)
        time.sleep(0.5)

    def _actual_freq(self, freq):
        return int((freq/self.f_samp)*(2**self.phase_bits))*self.f_samp/2**self.phase_bits
    
    def _period_samples(self, freq, OSR):
        return round(self.f_samp/freq*OSR)

    def sfdr_dBc(self, buffer_idx):
        with np.errstate(divide='ignore'):
            fft = 20*np.log10(abs(np.fft.rfft(self.dma_buffers[buffer_idx],axis=0))[1:-1])
        geo_mean = np.mean(fft) + 20
        # never will have issues with distortion on digital signal, but check if we've saturated the AFE signal-chain
        peaks,_ = scipy.signal.find_peaks(fft, distance=1000, height=geo_mean)
        spurs = np.sort(fft[peaks])[-2:]
        if np.max(fft) < geo_mean + 20:
            if self.dbg:
                print('saturation detected in AFE')
            return np.array([0, spurs[1]-spurs[0]])
        if self.plot:
            plt.figure()
            freqs = np.linspace(0,self.f_samp/2,fft.shape[0])
            plt.plot(freqs, fft)
            plt.plot(freqs[peaks],fft[peaks],'x')
        if self.dbg:
            print(f'spurs = {spurs}')
        return spurs[1]-spurs[0]
    
    def sinad_dBc(self, buffer_idx):
        # based on matlab's snr()
        # only removes the fundamental and DC (so distortion is included)
        [f, Pxx_den] = scipy.signal.periodogram(self.dma_buffers[buffer_idx], self.f_samp, window=('kaiser', 38), axis=0)
        # set DC component to 0
        Pxx_den[0] = 0
        if self.plot:
            fig, ax = plt.subplots(3,1)
            ax[0].semilogy(f, Pxx_den)
            ax[0].set_ylabel('PSD [V**2/Hz]')
        # find fundamental
        k0 = np.argmax(Pxx_den)
        # spectral width of kaiser window
        width = int(np.ceil(2*(1+(38/np.pi)**2)**0.5))
        # get power in fundamental
        Pxx_den_fund = np.zeros(Pxx_den.shape)
        Pxx_den_fund[k0-width:k0+width] = Pxx_den[k0-width:k0+width]
        # remove fundamental
        Pxx_den[k0-width:k0+width] = 0
        if self.plot:
            ax[1].semilogy(f, Pxx_den)
            ax[2].semilogy(f, Pxx_den_fund)
            ax[2].set_xlabel('freq [Hz]')
            ax[1].set_ylabel('PSD [V**2/Hz]')
            ax[2].set_ylabel('PSD [V**2/Hz]')
        pnoise = np.trapz(Pxx_den, f, axis=0)
        psignal = np.trapz(Pxx_den_fund, f, axis=0)
        sinad = psignal/pnoise
        return 10*np.log10(sinad), psignal, pnoise

    def measure_phase(self, source, tones, OSR=1024, vga_atten_dB=18, dac_atten_dB=12):
        n_intersect, uncertainty = self._coarse_delay_n(source, tones, vga_atten_dB, dac_atten_dB)
        fine_delay_n_corrected = self._fine_delay_n_correction(tones, n_intersect, n_intersect[0] - n_intersect[1], OSR)
        if self.plot:
            # upsample middle of data (transition point) and shift by corrected delay
            # normalize signal with an integer number of periods
            mean = np.mean(self.dma_buffers[0][:(1000//self._period_samples(tones[0],1))*self._period_samples(tones[0],1),:]*[-1,1], axis=0)
            std = np.std(self.dma_buffers[0][:(1000//self._period_samples(tones[0],1))*self._period_samples(tones[0],1),:]*[-1,1], axis=0)
            N_samp_left = min(4*self._period_samples(tones[0],1), n_intersect[1])
            N_samp_right = 7*self._period_samples(tones[0],1)
            middle = np.zeros((N_samp_left + N_samp_right, 2))
            middle[:,0] = -1*self.dma_buffers[0][n_intersect[1]-N_samp_left+fine_delay_n_corrected//OSR:n_intersect[1]+N_samp_right+fine_delay_n_corrected//OSR,0]
            middle[:,1] = self.dma_buffers[0][n_intersect[1]-N_samp_left:n_intersect[1]+N_samp_right,1]
            middle_upsampled = scipy.signal.resample_poly(middle,OSR,1,axis=0)
            shift = fine_delay_n_corrected % OSR
            if shift != 0:
                middle_upsampled_shifted = np.zeros((len(middle_upsampled)-shift,2))
                middle_upsampled_unshifted = middle_upsampled[:-shift,:]
                middle_upsampled_shifted[:,0] = middle_upsampled[shift:,0]
                middle_upsampled_shifted[:,1] = middle_upsampled[:-shift,1]
            else:
                middle_upsampled_shifted = middle_upsampled
                middle_upsampled_unshifted = middle_upsampled
            middle = (middle - mean)/std
            middle_upsampled_unshifted = (middle_upsampled_unshifted - mean)/std
            middle_upsampled_shifted = (middle_upsampled_shifted - mean)/std
            plt.figure()
            plt.plot(np.arange(len(middle_upsampled_shifted))/OSR, middle_upsampled_shifted, '-')
            plt.title('frequency transition')
            fig, ax = plt.subplots(1,2)
            ax[0].plot(np.arange(len(middle_upsampled_unshifted))/OSR, middle_upsampled_unshifted, '-')
            ax[1].plot(np.arange(len(middle_upsampled_shifted))/OSR, middle_upsampled_shifted, '-')
            for i in range(2):
                ax[i].axhline(y=0, color='k', linestyle='-')
                # find second zero crossing
                center = np.where(np.diff(np.sign(middle_upsampled_shifted[:,0])))[0][1] / OSR
                ax[i].set_xlim([center - 1, center + 1])
                ax[i].set_ylim([-0.1, 0.1])
            ax[0].set_title('reference tone')
            ax[1].set_title('reference tone shifted')
            fig.suptitle('upsampled reference tone, zoomed in on transition')
            # plot zoomed in on transition
            zero_crossings = np.where(np.diff(np.sign(middle_upsampled_shifted[:,0])))[0]
            deltas = np.diff(zero_crossings)
            center = zero_crossings[np.argmin(np.diff(deltas))+2]
            fig, ax = plt.subplots(2,1)
            for i in range(2):
                ax[i].plot(np.transpose([np.arange(len(middle)) - shift/OSR, np.arange(len(middle))]), middle, '.', label=['analog raw', 'digital raw'])
                ax[i].plot(np.arange(len(middle_upsampled_shifted))/OSR, middle_upsampled_shifted, '-', label=['analog upsampled', 'digital upsampled'])
            ax[0].set_xlim([center/OSR - self._period_samples(tones[0],1), center/OSR + 4*self._period_samples(tones[1],1)])
            ax[1].set_xlim([center/OSR - self._period_samples(tones[0],1)/4, center/OSR + 2*self._period_samples(tones[1],1)])
            ax[0].set_title('transition')
            ax[1].set_title('transition zoomed')
            fig.suptitle('closeup of transition')
        # resample final periods of test tone
        N_samp = max((1000//self._period_samples(tones[1],1))*self._period_samples(tones[1],1), 2*self._period_samples(tones[1],1))
        test = np.zeros((N_samp, 2))
        n_min = round(n_intersect[0] + 5*uncertainty + 2*self.f_samp/tones[0])
        test[:,0] = -1*self.dma_buffers[0][n_min+fine_delay_n_corrected//OSR:n_min+N_samp+fine_delay_n_corrected//OSR,0]
        test[:,1] = self.dma_buffers[0][n_min:n_min+N_samp,1]
        test_upsampled = scipy.signal.resample_poly(test,OSR,1,axis=0)
        # shift again by residual of correction
        shift = fine_delay_n_corrected % OSR
        if shift != 0:
            test_upsampled_shifted = np.zeros((len(test_upsampled)-shift,2))
            test_upsampled_shifted[:,0] = test_upsampled[shift:,0]
            test_upsampled_shifted[:,1] = test_upsampled[:-shift,1]
        else:
            test_upsampled_shifted = test_upsampled
        if self.plot:
            plt.figure()
            plt.plot(np.transpose([np.arange(0,N_samp) - shift/OSR, np.arange(0,N_samp)]), (test - np.mean(test, axis=0))/np.std(test, axis=0), '.')
            plt.plot(np.arange(0,len(test_upsampled_shifted))/OSR, (test_upsampled_shifted - np.mean(test_upsampled_shifted, axis=0))/np.std(test_upsampled_shifted, axis=0), '-')
            plt.xlim([N_samp//2-N_samp//8,N_samp//2+N_samp//8])
            plt.title('test waveform')
        # get phase using covariance method with middle samples
        #N_samp = max(self._period_samples(tones[1],OSR), (N_samp//2 - 4*self._period_samples(tones[1],1))*OSR)
        #N_samp = min(4*self._period_samples(tones[1],OSR), (N_samp//2)*OSR)
        # crop out tails to get a more pure sinusoid
        N_tail = 5*self._period_samples(self.f_samp/2,OSR)
        zero_crossings = np.where(np.diff(np.sign(test_upsampled_shifted[N_tail:-N_tail,0])))[0] # force starting at a zero crossing
        n_min = zero_crossings[0]
        n_max = zero_crossings[-1]
        sectioned = test_upsampled_shifted[n_min:n_max,:]
        sectioned = (sectioned - np.mean(sectioned, axis=0))/np.std(sectioned, axis=0)
        xcorr = scipy.signal.correlate(sectioned[:,0], sectioned[:,1])
        lags = scipy.signal.correlation_lags(sectioned.shape[0], sectioned.shape[0])
        phi = 2*np.pi*lags[np.argmax(xcorr)]*self._actual_freq(tones[1])/(self.f_samp*OSR) % (2*np.pi)
        if self.dbg:
            print(f'phi = {phi} ({phi*180/np.pi} deg)')
        if self.plot:
            fig, ax = plt.subplots(2,1)
            ax[0].plot(np.arange(len(sectioned))/OSR, sectioned, '-')
            ax[0].axhline(y=0, color='k', linestyle='-')
            ax[1].plot(np.arange(len(sectioned))*360*self._actual_freq(tones[1])/(self.f_samp*OSR), sectioned, '-')
            center = np.where(np.diff(np.sign(sectioned[:,0])))[0][1]*360*self._actual_freq(tones[1])/(self.f_samp*OSR)
            ax[1].set_xlim([center - 90, center + 90])
            ax[1].axhline(y=0, color='k', linestyle='-')
            fig.suptitle('waveform used to compute phase')
        return phi

    def _coarse_delay_n(self, source, tones, vga_atten_dB, dac_atten_dB):
        if self.dbg:
            print(f'measuring phase delay of frequency {round(tones[1]/1e6)}MHz with reference {round(tones[0]/1e6)}MHz')
        # get coarse phase delay with spectrogram
        self.set_vga_atten_dB(vga_atten_dB)
        self.set_dac_atten_dB(12)
        self.set_adc_source(source)
        self.set_sample_buffer_trigger_source('manual')
        self.set_freq_hz(tones[0])
        self.set_sample_buffer_trigger_source('dds_auto')
        self.set_freq_hz(tones[1])
        self.dma(0)
        # only need first 4096 samples
        raw = self.dma_buffers[0][:4096,:]*[-1, 1]
        # use zero-crossing technique
        zero_crossings_analog = np.where(np.diff(np.sign(self.dma_buffers[0][:4096,0]),axis=0))[0]
        zero_crossings_digital = np.where(np.diff(np.sign(self.dma_buffers[0][:4096,1]),axis=0))[0]
        # clean zero crossings; if any pairs are closer together than 0.4*self._period_samples(tones[1],1)
        # (i.e. spacing corresponding to 80% of minimum period), skip one of them
        min_dist = 0.4*self._period_samples(tones[1],1)
        zero_crossings_analog = zero_crossings_analog[np.diff(zero_crossings_analog,append=zero_crossings_analog[-1]+min_dist*1.2) > min_dist]
        zero_crossings_digital = zero_crossings_digital[np.diff(zero_crossings_digital,append=zero_crossings_digital[-1]+min_dist*1.2) > min_dist]
        n_shift_analog = zero_crossings_analog[np.argmin(np.diff(np.diff(zero_crossings_analog)))+2]
        n_shift_digital = zero_crossings_digital[np.argmin(np.diff(np.diff(zero_crossings_digital)))+2]
        n_intersect = np.array([n_shift_analog, n_shift_digital])
        uncertainty = self._period_samples(tones[0], 1)
        if self.dbg:
            coarse_delay_n = n_intersect[0] - n_intersect[1]
            print(f'n_intersect = {n_intersect}')
            print(f't_intersect = {n_intersect/self.f_samp}')
            print(f'coarse_delay_n = {coarse_delay_n}')
            print(f'uncertainty = {uncertainty} = {uncertainty/self.f_samp*1e9}ns')
        if self.plot:
            raw = self.dma_buffers[0][:4096,:]*[-1, 1]
            raw = (raw - np.mean(raw, axis=0))/np.std(raw, axis=0)
            plt.figure()
            plt.plot(raw + [4, 0], '.', label=['analog', 'digital'])
            plt.legend()
            plt.title('raw data')
            fig, ax = plt.subplots(2,1)
            ax[0].plot(raw[:,0], '.', label='analog raw samples')
            ax[0].set_xlim([n_shift_analog - self._period_samples(tones[0],1), n_shift_analog + self._period_samples(tones[0],1)])
            ax[0].legend()
            ax[1].plot(raw[:,1], '.', label='digital raw samples')
            ax[1].set_xlim([n_shift_digital - self._period_samples(tones[0],1), n_shift_digital + self._period_samples(tones[0],1)])
            ax[1].legend()
            fig.suptitle('raw data zoom')
            plt.figure()
            plt.plot(np.diff(zero_crossings_analog), '.', label='analog')
            plt.plot(np.diff(zero_crossings_analog), '.', label='digital')
            plt.title('delay between zero-crossings')
        return n_intersect, uncertainty

    def _fine_delay_n_correction(self, tones, n_intersect, coarse_delay_n_crossover, OSR):
        # first shift by coarse_delay_n_crossover, then resample 2*OSR periods
        N_samp = min(2*OSR*self._period_samples(tones[0],1), round(n_intersect[1]))
        reference = np.zeros((N_samp, 2))
        reference[:,0] = -1*self.dma_buffers[0][coarse_delay_n_crossover:coarse_delay_n_crossover+N_samp,0]
        reference[:,1] = self.dma_buffers[0][:N_samp,1]
        reference_upsampled = scipy.signal.resample_poly(reference,OSR,1,axis=0)
        # crop out tails to get a more pure sinusoid
        N_tail = 5*self._period_samples(self.f_samp/2,OSR)
        zero_crossings = np.where(np.diff(np.sign(reference_upsampled[N_tail:-N_tail,0])))[0] # force starting at a zero crossing
        n_min = zero_crossings[0]
        n_max = zero_crossings[-1]
        reference_upsampled = reference_upsampled[n_min:n_max]
        mean = np.mean(reference_upsampled,axis=0)
        std = np.std(reference_upsampled,axis=0)
        reference_upsampled = (reference_upsampled - mean)/std
        reference_upsampled *= np.transpose([np.hanning(len(reference_upsampled)), np.hanning(len(reference_upsampled))])
        xcorr = scipy.signal.correlate(reference_upsampled[:,0], reference_upsampled[:,1])
        lags = scipy.signal.correlation_lags(len(reference_upsampled), len(reference_upsampled))
        fine_delay_n_correction = coarse_delay_n_crossover*OSR + lags[np.argmax(xcorr)]
        if self.plot:
            n = np.arange(len(reference_upsampled))/OSR
            plt.figure()
            plt.plot(n, reference_upsampled, '-')
            plt.title('upsampled reference tone (windowed)')
            # plot zoom
            fig, ax = plt.subplots(1,2)
            ax[0].plot(n, reference_upsampled, '-')
            ax[1].plot(np.transpose([n - lags[np.argmax(xcorr)]/OSR, n]), reference_upsampled, '-')
            for i in range(2):
                ax[i].axhline(y=0, color='k', linestyle='-')
                zero_crossings = np.where(np.diff(np.sign(reference_upsampled[:,0])))[0]
                center = zero_crossings[len(zero_crossings)//2] / OSR - lags[np.argmax(xcorr)] / OSR
                ax[i].set_xlim([center - 1, center + 1])
                ax[i].set_ylim([-0.1, 0.1])
            ax[0].set_title('original reference tone')
            ax[1].set_title('reference tone fine correction')
            fig.suptitle('upsampled reference tone, zoomed in on transition')
            fig, ax = plt.subplots(2,1)
            ax[0].plot(lags/OSR, xcorr)
            ax[1].plot(lags/OSR, xcorr)
            ax[1].set_xlim([lags[np.argmax(xcorr)]/OSR - self._period_samples(tones[0],OSR)/OSR, lags[np.argmax(xcorr)]/OSR + self._period_samples(tones[0],OSR)/OSR])
            fig.suptitle('lags')
        if self.dbg:
            # get covariance
            print(f'lags[np.argmax(xcorr)] = {lags[np.argmax(xcorr)]} = {lags[np.argmax(xcorr)]/OSR}*{OSR}')
            print(f'fine_delay_n_correction = {fine_delay_n_correction} = {fine_delay_n_correction/OSR}*{OSR}')
        # 1 sample delay due to the sample-and-hold of the DAC
        return fine_delay_n_correction - 1*OSR

    def set_freq_hz(self, freq_hz, channel = 0):
        pinc = int((freq_hz/self.f_samp)*(2**self.phase_bits))
        if self.dbg:
            print(f'setting pinc to {pinc} ({freq_hz:.3e}Hz)')
        self.pinc[channel].send_tx_pkt([pinc])
        time.sleep(self.t_sleep)

    def set_dac_atten_dB(self, atten_dB, channel = 0):
        scale = round(atten_dB/6)
        if scale < 0 or scale > 15:
            raise ValueError("cannot set attenuation less than 0dB or more than 90dB")
        if self.dbg:
            print(f'setting cos_scale to {scale} ({6*scale}dB attenuation)')
        self.cos_scale[channel].send_tx_pkt([scale])
        time.sleep(self.t_sleep)

    def set_vga_atten_dB(self, atten_dB, channel = 0):
        atten_dB = round(atten_dB)
        if atten_dB < 0 or atten_dB > 32:
            raise ValueError("atten_dB out of range, pick a number between 0 and 32dB")
        packet = 0x0200 | (atten_dB & 0x3f) # address 0x02, 6-bit data atten_dB
        packet |= channel << 16 # address/channel ID is above 16-bit address+data
        if self.dbg:
            print(f'setting vga attenuation to {atten_dB}dB')
            print(f'packet = {hex(packet)}')
        self.lmh6401.send_tx_pkt([packet])
        time.sleep(self.t_sleep)

    def set_adc_source(self, adc_source):
        if (adc_source == 'afe') or (adc_source == 0):
            self.adc_select.off()
        elif (adc_source == 'balun') or (adc_source == 1):
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
