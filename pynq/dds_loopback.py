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
