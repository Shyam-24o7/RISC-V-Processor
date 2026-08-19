# Batch synthesis for Fmax and utilisation. Invoked from WSL through interop:
#   /mnt/d/Vivado/2022.2/bin/vivado.bat -mode batch -source scripts/synth.tcl -tclargs core_sc
#
# All paths are relative to the repo root, which is also Vivado's working
# directory, so the space in the repo path never reaches a Make prerequisite.

set core [lindex $argv 0]
if {$core eq ""} { set core core_sc }

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
  rtl/common/mul_div.sv \
  rtl/common/csr_file.sv \
  rtl/$core/$core.sv ]

create_project -in_memory -part $part
foreach s $srcs { read_verilog -sv $s }
set_property top $core [current_fileset]

# Constrain aggressively, then derive Fmax from the achieved slack:
#   Fmax = 1 / (target_period - WNS)
# A single pass is enough because WNS is signed - a missed target gives a
# negative slack and still yields the true achievable period.
set target_ns 4.0
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
