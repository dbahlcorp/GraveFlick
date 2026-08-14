// GraveFlick gameplay ambience
// Original algorithmic composition rendered with the free, open-source Strudel REPL.
// Uses synthesized oscillators only: no samples, melodies, or recordings from third parties.
// Export: cycles 0...8, 44.1 kHz, stereo WAV, multi-channel orbits disabled.

setcpm(64 / 4)

stack(
  note("<d1 bb0 c1 a0>")
    .s("sawtooth").lpf(sine.range(110, 260).slow(8)).gain(.18).attack(.8).release(2.5).room(.85).size(.9),
  note("<[d2,a2] [bb1,f2] [c2,g2] [a1,e2]>")
    .s("triangle").lpf(520).gain(.10).attack(1.2).release(2.8).room(.9).size(.9),
  note("[~ ~ d4 ~ ~ eb4 ~ a3]/2")
    .s("sine").gain(.035).attack(.05).release(1.6).delay(.4).room(.85),
  note("d0 ~ ~ ~ d0 ~ a0 ~")
    .s("sine").gain(.12).attack(.01).release(.22),
  note("[d5 ~ ~ ~ ~ ~ c#5 ~]/2")
    .s("square").lpf(850).gain(.018).attack(.01).release(.08).delay(.6)
)
