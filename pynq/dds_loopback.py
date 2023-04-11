import os
from pynq import Overlay
from pynq import allocate
import xrfclk
import numpy as np
import matplotlib.pyplot as plt
from axitimer import AxiTimerDriver
import scipy.signal
import scipy.io
import time
import serial

class DDSOverlay(Overlay):
    def __init__(self, bitfile_name=None, dbg=False, plot=False, n_buffers=1, **kwargs):
        if bitfile_name is None:
            this_dir = os.path.dirname(__file__)
            bitfile_name = os.path.join(this_dir, 'hw', 'top.bit')
        if dbg:
            print(f'loading bitfile {bitfile_name}')
        super().__init__(bitfile_name, **kwargs)
        self.dma_recv = self.axi_dma_0.recvchannel
        self.capture_trig = self.axi_gpio_capture.channel1[0]
        self.pinc = self.axi_gpio_pinc.channel1
        self.cos_scale = self.axi_gpio_scale.channel1
        self.timer = self.axi_timer_0
        xrfclk.set_ref_clks(lmk_freq=122.88, lmx_freq=409.6)
        self.f_samp = 4.096e9 # Hz
        self.phase_bits = 24
        self.timer.start_tmr()
        self.dma_frame_size = 32*65536
        alloc_bytes = n_buffers * self.dma_frame_size * 2 
        if (alloc_bytes > 3e9):
            raise ValueError(f"refusing to allocate {round(alloc_bytes/(2**20))}MiB of DMA buffer, try again with smaller n_buffers")
        self.dma_buffers = [allocate(shape=(self.dma_frame_size,), dtype=np.int16) for i in range(n_buffers)]
        self.dbg = dbg
        self.plot = plot
        self.raspi = None
        for i in range(10):
            try:
                self.raspi = serial.Serial(f'/dev/ttyACM{i}')
                if self.dbg:
                    print(f'connected to raspberry pi pico on {self.raspi.name}')
                break
            except (OSError, serial.SerialException):
                pass
        if self.raspi is None:
            raise Warning('could not connect to raspberry pi pico. variable gain will not work')
        else:
            while self.raspi.in_waiting:
                l = self.raspi.readline()
                if self.dbg:
                    print(l)
    
    def set_freq_hz(self, freq_hz):
        pinc = int((freq_hz/self.f_samp)*(2**self.phase_bits))
        if self.dbg:
            print(f'setting pinc to {pinc} ({freq_hz:.3e}Hz)')
        self.pinc.write(pinc,0xffffff)
    
    def set_dac_atten_dB(self, atten_dB):
        scale = round(atten_dB/6)
        if scale < 0 or scale > 15:
            raise ValueError("cannot set attenuation less than 0dB or more than 90dB")
        if self.dbg:
            print(f'setting cos_scale to {scale} ({6*scale}dB attenuation)')
        self.cos_scale.write(scale, 0xf)
    
    def set_vga_atten_dB(self, atten_dB):
        atten_dB = round(atten_dB)
        if self.dbg:
            print(f'setting vga attenuation to {atten_dB}dB')
        send_bytes = b'\r\n'
        if atten_dB == 0:
            send_bytes = b'0' + send_bytes
        else:
            while atten_dB > 0:
                send_bytes = ((atten_dB % 10) + ord('0')).to_bytes(1,byteorder='big') + send_bytes
                atten_dB //= 10
        self.raspi.write(send_bytes)
        while self.raspi.in_waiting:
            l = self.raspi.readline()
            if self.dbg:
                print(l)
    
    def realloc_buffers(self, n_buffers):
        if len(self.dma_buffers) == n_buffers:
            return
        alloc_bytes = n_buffers * self.dma_frame_size * 2 
        if (alloc_bytes > 1e9):
            raise ValueError(f"refusing to allocate {round(alloc_bytes/(2**20))}MiB of DMA buffer, try again with smaller n_buffers")
        del self.dma_buffers
        self.dma_buffers = [allocate(shape=(self.dma_frame_size,), dtype=np.int16) for i in range(n_buffers)]
    
    def capture_data(self, buffer, N_samp=128, OSR=256):
        self.capture_trig.on()
        self.capture_trig.off()
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
            plt.plot(tvec,buffer[N_samp:2*N_samp], '.')
            plt.plot(tvec_osr,scipy.signal.resample_poly(np.array(buffer[:8*N_samp],dtype=np.float32),OSR,1)[N_samp*OSR:2*N_samp*OSR], '-')
    
    def do_freq_sweep(self, name, dac_atten_dB, vga_atten_dB, freqs):
        self.set_dac_atten_dB(dac_atten_dB)
        self.set_vga_atten_dB(vga_atten_dB)
        self.realloc_buffers(len(freqs))
        for i,freq in enumerate(freqs):
            self.set_freq_hz(freq)
            self.capture_data(self.dma_buffers[i])
        scipy.io.savemat(name, {"tdata": np.array(self.dma_buffers), "freqs_hz": np.array(freqs), "dma_size": self.dma_frame_size, "dac_atten_dB": dac_atten_dB})
