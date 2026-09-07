# Batch synthesis for Fmax and utilisation. Invoked from WSL through interop:
#   /mnt/d/Vivado/2022.2/bin/vivado.bat -mode batch -source scripts/synth.tcl -tclargs core_rv32i
#
# All paths are relative to the repo root, which is also Vivado's working
# directory, so the space in the repo path never reaches a Make prerequisite.

set core [lindex $argv 0]
if {$core eq ""} { set core core_rv32i }

set part xck26-sfvc784-2LV-c
set outdir build_vivado/$core
file mkdir $outdir

# magic_mem is deliberately excluded: it is a simulation construct using
# $readmemh and an initial block. The FPGA build would instantiate real BRAM.
#
# CAVEAT this makes the reported Fmax OPTIMISTIC for Phase 1 specifically. A
# real single-cycle core must fit instruction fetch AND data access inside the
# same clock period; with memory outside the synthesised boundary, that access
# time is not in any measured path. Phases 2+ register the memory interface, so
# their numbers are not distorted the same way. Do not read the Phase 1 Fmax as
# achievable for a standalone single-cycle CPU with memory attached.
set srcs [list \
  rtl/common/rv32_pkg.sv \
  rtl/common/alu.sv \
  rtl/common/regfile.sv \
  rtl/common/decoder.sv \
  rtl/common/csr_file.sv \
  rtl/core/$core.sv ]

create_project -in_memory -part $part
foreach s $srcs { read_verilog -sv $s }
set_property top $core [current_fileset]

# Derive Fmax from the achieved slack:  Fmax = 1 / (target_period - WNS)
#
# One pass is enough, in EITHER direction. It is reasonable to worry that a
# design which MEETS its constraint has simply stopped being optimised, making
# the derived Fmax a property of the constraint rather than the design - but
# that was measured here and is not what happens. core_rv32i_p5 synthesised at
# both 4.0 ns (wns +0.021) and 3.0 ns (wns -0.979) reports an achieved period of
# 3.979 ns either way, i.e. the same 251.3 MHz. Vivado reports the true
# worst-case path regardless of whether the target was met.
#
# The target is settable anyway, as a second argument, so that assumption can be
# re-checked cheaply on any future design rather than trusted.
set target_ns 4.0
if {[llength $argv] > 1} { set target_ns [lindex $argv 1] }
puts "SYNTH target period = $target_ns ns"
synth_design -top $core -part $part -flatten_hierarchy rebuilt
create_clock -period $target_ns -name clk [get_ports clk_i]
opt_design

report_utilization -file $outdir/utilization.rpt
report_timing_summary -file $outdir/timing.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set achieved_ns [expr {$target_ns - $wns}]
set fmax_mhz [expr {1000.0 / $achieved_ns}]

# Parse report_utilization rather than filtering on PRIMITIVE_GROUP. That
# property does not partition the way the report does: querying ARITHMETIC
# returned 108 for a design with 12 DSPs (it also swept up the carry chains),
# and LUT/FLOP_LATCH matched nothing at all. The report is the authority.
proc util_row {file name} {
  if {![file exists $file]} { return 0 }
  set fh [open $file r]
  set data [read $fh]
  close $fh
  foreach line [split $data "\n"] {
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\\d+)\\s+\\|" $line -> n]} {
      return $n
    }
  }
  return 0
}
set urpt   $outdir/utilization.rpt
set n_lut  [util_row $urpt "CLB LUTs"]
set n_ff   [util_row $urpt "CLB Registers"]
set n_dsp  [util_row $urpt "DSPs"]
set n_bram [util_row $urpt "Block RAM Tile"]

set fh [open $outdir/summary.json w]
puts $fh "{"
puts $fh "  \"core\": \"$core\","
puts $fh "  \"part\": \"$part\","
puts $fh "  \"fmax_mhz\": [format %.1f $fmax_mhz],"
puts $fh "  \"wns_ns\": [format %.3f $wns],"
puts $fh "  \"target_ns\": $target_ns,"
puts $fh "  \"lut\": $n_lut,"
puts $fh "  \"ff\": $n_ff,"
puts $fh "  \"dsp\": $n_dsp,"
puts $fh "  \"bram\": $n_bram"
puts $fh "}"
close $fh

puts "SYNTH DONE $core Fmax=[format %.1f $fmax_mhz] MHz WNS=$wns ns LUT=$n_lut FF=$n_ff DSP=$n_dsp BRAM=$n_bram"
