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

class NoiseOverlay(Overlay):
    def __init__(self, bitfile_name=None, dbg=False, plot=False, **kwargs):
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
        self.pinc = [self.dds_hier_0.axi_fifo_pinc_0, self.dds_hier_1.axi_fifo_pinc_1]
        self.dac_coarse_scale = [self.dds_hier_0.axi_fifo_scale_0, self.dds_hier_1.axi_fifo_scale_1]
        self.dac_fine_scale = [self.dds_hier_0.axi_fifo_dac_scale_0, self.dds_hier_1.axi_fifo_dac_scale_1]
        self.timer = self.axi_timer_0
        self.lmh6401 = self.lmh6401_hier.axi_fifo_lmh6401
        self.noise_buffer = self.noise_tracker.axi_fifo_noise_buf_cfg
        self.adc_gain = [self.noise_tracker.adc00_energy_downsample.axi_fifo_adc_gain, self.noise_tracker.adc02_energy_downsample.axi_fifo_adc_gain]
        
        xrfclk.set_ref_clks(lmk_freq=122.88, lmx_freq=409.6)
        if dbg:
            print('set clocks')
        
        self.f_samp = 4.096e9 # Hz
        self.phase_bits = 32
        self.timer.start_tmr()
        self.axi_mm_width_words = 8 # 128-bit / 16 bit/word
        self.noise_buffer_sample_depth = 2**15
        self.dma_frame_size = self.noise_buffer_sample_depth * self.axi_mm_width_words
        self.dma_frame_shape = (self.dma_frame_size,)
        # we can use unsigned types since the noise will always be a positive number
        # actually this is not quite true, since we're applying a lowpass filter after squaring the signal, we could end up with some close-to-zero values going below zero
        self.dma_buffer = allocate(shape=self.dma_frame_shape, dtype=np.uint16)
        self.dbg = dbg
        self.plot = plot
        # seems like there are sometimes AXI transaction reorderings, so add a delay as a 
        # sort of "manual fence"
        # having a single AXI-slave device with multiple registers instead of
        # separate AXI GPIOs should prevent issues arising from transaction reordering
        self.t_sleep = 0.008
        # thresholds for sample discriminator
        self.threshold_low = 0
        self.threshold_high = 0

    def set_freq_hz(self, freq_hz, channel = 0):
        pinc = int((freq_hz/self.f_samp)*(2**self.phase_bits))
        if self.dbg:
            print(f'setting pinc to {pinc} ({freq_hz:.3e}Hz)')
        # send_tx_pkt accepts a list of 32-bit integers to send
        self.pinc[channel].send_tx_pkt([pinc])
        time.sleep(self.t_sleep)

    def set_dac_atten_dB(self, atten_dB, channel = 0):
        scale = round(atten_dB/6)
        if scale < 0 or scale > 15:
            raise ValueError("cannot set attenuation less than 0dB or more than 90dB")
        if self.dbg:
            print(f'setting cos_scale to {scale} ({6*scale}dB attenuation)')
        self.dac_coarse_scale[channel].send_tx_pkt([scale])
        time.sleep(self.t_sleep)
        
    def set_dac_scale_factor(self, scale, channel = 0):
        # scale is 2Q16, so quantize appropriately
        quant = int(scale * 2**16)
        if (quant >> 16) > 1 or (quant >> 16) < -2:
            raise ValueError(f'cannot quantize {scale} to 2Q16')
        if quant < 0:
            quant += 2**18
        # write to fifo
        if self.dbg:
            print(f'setting dac_prescale scale_factor to {quant / 2**16 - (0 if quant < 2**17 else 4)} ({quant:05x})')
        self.dac_fine_scale[channel].send_tx_pkt([quant])
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
    
    def set_adc_digital_gain(self, gain, channel = 0):
        # scale is 2Q16, so quantize appropriately
        quant = int(gain * 2**16)
        if (quant >> 16) > 1 or (quant >> 16) < -2:
            raise ValueError(f'cannot quantize {gain} to 2Q16')
        if quant < 0:
            quant += 2**18
        # write to fifo
        if self.dbg:
            print(f'setting adc_gain scale_factor to {quant / 2**16 - (0 if quant < 2**17 else 4)} ({quant:05x})')
        self.adc_gain[channel].send_tx_pkt([quant])
        time.sleep(self.t_sleep)
        

    def dma(self):
        time.sleep(self.t_sleep)
        self.dma_recv.transfer(self.dma_buffer)
        time.sleep(self.t_sleep)
        
    def set_discriminator_threshold(self, thresh_high, thresh_low = None):
        # configuration packet is 34 bits, so we need two words
        # {mode, start, stop, threshold_high, threshold_low}
        # always capture start: {1, 0, 16'b0, 16'b1}
        # always capture stop: {0, 1, 16'b0, 16'b1}
        if thresh_low is None:
            thresh_low = thresh_high
        self.threshold_low = int(thresh_low * 2**16)
        self.threshold_high = int(thresh_high * 2**16)
        packet = [(((self.threshold_high & 0xffff) << 16) | (self.threshold_low & 0xffff)), 0x0]
        if self.dbg:
            print(f'setting discriminator thresholds {thresh_low}-{thresh_high}')
            print(f'packet = {[hex(p) for p in packet]}')
        self.noise_buffer.send_tx_pkt(packet)
    
    def start_capture(self):
        packet = [(((self.threshold_high & 0xffff) << 16) | (self.threshold_low & 0xffff)), 0x2]
        if self.dbg:
            print(f'sending start command with discriminator thresholds {self.threshold_high & 0xffff}:{self.threshold_low & 0xffff}')
            print(f'packet = {[hex(p) for p in packet]}')
        self.noise_buffer.send_tx_pkt(packet)
    
    def stop_capture(self):
        packet = [(((self.threshold_high & 0xffff) << 16) | (self.threshold_low & 0xffff)), 0x1]
        if self.dbg:
            print(f'sending stop command with discriminator thresholds {self.threshold_high & 0xffff}:{self.threshold_low & 0xffff}')
            print(f'packet = {[hex(p) for p in packet]}')
        self.noise_buffer.send_tx_pkt(packet)