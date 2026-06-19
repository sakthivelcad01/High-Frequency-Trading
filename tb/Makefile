# e:\Verilog_HFT_FPGA\tb\Makefile
# Cocotb simulation Makefile

SIM ?= icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES += $(PWD)/../rtl/network_parser.v

TOPLEVEL = network_parser
MODULE = test_parser

include $(shell cocotb-config --makefiles)/Makefile.sim
