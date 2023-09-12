set_property -dict { PACKAGE_PIN AP5   IOSTANDARD LVCMOS18 } [get_ports sck]; # ADCIO_00
set_property -dict { PACKAGE_PIN AP6   IOSTANDARD LVCMOS18 } [get_ports sdi]; # ADCIO_01
set_property -dict { PACKAGE_PIN AR7   IOSTANDARD LVCMOS18 } [get_ports { cs_n[0] }]; # ADCIO_03
set_property -dict { PACKAGE_PIN AV7   IOSTANDARD LVCMOS18 } [get_ports { cs_n[1] }]; # ADCIO_04
set_property -dict { PACKAGE_PIN AU3   IOSTANDARD LVCMOS18 } [get_ports { ADCIO[12] }];
set_property -dict { PACKAGE_PIN AU4   IOSTANDARD LVCMOS18 } [get_ports { ADCIO[13] }];
set_property -dict { PACKAGE_PIN AV5   IOSTANDARD LVCMOS18 } [get_ports { ADCIO[14] }];
set_property -dict { PACKAGE_PIN AV6   IOSTANDARD LVCMOS18 } [get_ports { ADCIO[15] }];
set_property -dict { PACKAGE_PIN AU1   IOSTANDARD LVCMOS18 } [get_ports { ADCIO[16] }];
set_property -dict { PACKAGE_PIN AU2   IOSTANDARD LVCMOS18 } [get_ports { ADCIO[17] }];
set_property -dict { PACKAGE_PIN AV2   IOSTANDARD LVCMOS18 } [get_ports { ADCIO[18] }];
set_property -dict { PACKAGE_PIN AV3   IOSTANDARD LVCMOS18 } [get_ports { ADCIO[19] }];
