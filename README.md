# rfsoc_dds

 Systemverilog for direct digital synthesis of high-purity sinusoids at full sample rate for use with RFSoCs.
 Also includes a sample buffer that can perform basic amplitude discrimination on input signals to generate sparse sequences of samples that are time-tagged.

## Repo structure

### `dds_test.srcs`:

Systemverilog for simulation and synthesis.
The key module for direct digital synthesis (DDS) is [here](dds_test.srcs/sources_1/new/dds.sv).
DDS is implemented multiple phase increment registers configured in parallel.
A four-quadrant lookup table is used (I didn't have the energy to optimize a single quadrant scheme to minimize phase quantization noise for only 4x improvement in storage space).
To reduce phase quantization noise, a maximal linear-feedback shift register (LFSR) is used to provide a 1-LSB dither signal.
While this increases the floor of the phase noise as compared to a 0.5-LSB dither, I found in testing that it reduced the correlated phase noise and improved the spurious-free dynamic range of the output.

