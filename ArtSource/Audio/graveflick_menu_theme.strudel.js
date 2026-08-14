// GraveFlick main-menu theme
// Original algorithmic composition rendered with the free, open-source Strudel REPL.
// Uses synthesized oscillators only: no samples, melodies, or recordings from third parties.
// Export: cycles 0...8, 44.1 kHz, stereo WAV, multi-channel orbits disabled.

setcpm(76 / 4)

stack(
  note("<d2 d2 bb1 c2>")
    .s("sawtooth").lpf(240).lpq(2).gain(.24).attack(.03).release(.28),
  note("<[d3,f3,a3] [d3,f3,a3] [bb2,d3,f3] [c3,e3,g3]>")
    .s("triangle").lpf(1050).gain(.12).attack(.08).release(1.4).room(.75).size(.85),
  note("[~ a4 ~ f4 ~ e4 ~ d4]/2")
    .s("square").lpf(1350).gain(.065).attack(.02).release(.25).delay(.32),
  note("d5 ~ ~ a4 ~ ~ c5 ~")
    .s("sine").slow(2).gain(.055).attack(.01).release(.9).room(.9),
  note("d1 ~ d1 ~ [d1 ~] ~ a0 ~")
    .s("sine").gain(.20).attack(.005).release(.15)
)
