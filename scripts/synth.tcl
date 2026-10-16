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

# CAVEAT: memory sits outside the synthesised boundary for the bare cores, so
# the single-cycle core's Fmax omits instruction and data access time, which a
# real single-cycle CPU must fit in its clock period. Treat it as optimistic.
#
# Every synthesisable source. rv32_pkg first: everything imports it.
# Simulation-only memories (magic_mem, latency_mem, main_mem) are excluded;
# read_verilog on files the top does not use is harmless.
set srcs [list rtl/common/rv32_pkg.sv]
foreach f [lsort [glob rtl/common/*.sv rtl/core/*.sv]] {
  if {$f ne "rtl/common/rv32_pkg.sv"} { lappend srcs $f }
}
foreach f {sram_1r1w icache dcache mem_arbiter} {
  if {[file exists rtl/mem/$f.sv]} { lappend srcs rtl/mem/$f.sv }
}
foreach f [glob -nocomplain rtl/soc/*.sv] { lappend srcs $f }

create_project -in_memory -part $part
foreach s $srcs { read_verilog -sv $s }
set_property top $core [current_fileset]

# Derive Fmax from the achieved slack:  Fmax = 1 / (target_period - WNS)
#
# Vivado reports the true worst-case path whether or not the target was met,
# so this holds in either direction. The target is settable as a second
# argument so that can be re-checked on any design.
set target_ns 4.0
if {[llength $argv] > 1} { set target_ns [lindex $argv 1] }
puts "SYNTH target period = $target_ns ns"
synth_design -top $core -part $part -flatten_hierarchy rebuilt
create_clock -period $target_ns -name clk [get_ports clk_i]
opt_design

report_utilization -file $outdir/utilization.rpt
report_timing_summary -file $outdir/timing.rpt

# A combinational loop makes every timing number meaningless: Vivado cuts the
# loop at an arbitrary point. Refuse to report an Fmax for such a design.
proc loop_count {file} {
  set fh [open $file r]; set data [read $fh]; close $fh
  if {[regexp {There (?:is|are) (\d+) combinational loop} $data -> n]} { return $n }
  return -1
}
set n_loops [loop_count $outdir/timing.rpt]
if {$n_loops != 0} {
  puts "SYNTH FAILED $core: combinational loops = $n_loops (see $outdir/timing.rpt)"
  exit 1
}

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
    if {[regexp "^\\|\\s+${name}\\*?\\s+\\|\\s+(\\d+(?:\\.\\d+)?)\\s+\\|" $line -> n]} {
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

# Spec success criterion: the cached system must infer block RAM. Zero means
# the cache arrays were built from LUTs and the utilisation figures would
# describe the wrong design.
if {$core eq "rv32_soc" && $n_bram == 0} {
  puts "SYNTH FAILED $core: no block RAM inferred (cache arrays built from LUTs?)"
  exit 1
}

set fh [open $outdir/summary.json w]
puts $fh "{"
puts $fh "  \"core\": \"$core\","
puts $fh "  \"part\": \"$part\","
puts $fh "  \"fmax_mhz\": [format %.1f $fmax_mhz],"
puts $fh "  \"wns_ns\": [format %.3f $wns],"
puts $fh "  \"target_ns\": $target_ns,"
puts $fh "  \"loops\": $n_loops,"
puts $fh "  \"lut\": $n_lut,"
puts $fh "  \"ff\": $n_ff,"
puts $fh "  \"dsp\": $n_dsp,"
puts $fh "  \"bram\": $n_bram"
puts $fh "}"
close $fh

puts "SYNTH DONE $core Fmax=[format %.1f $fmax_mhz] MHz WNS=$wns ns LUT=$n_lut FF=$n_ff DSP=$n_dsp BRAM=$n_bram"
