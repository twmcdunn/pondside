~lxFx[\granulator] = (defaults: (mix: 1, density: 20, grainDur: 0.08, delay: 0.3, scatter: 0.2, pitchJitter: 0, spread: 0.8),
	func: { |sig, p|
		var trig = Dust.ar(p[\density]);
		var back = (p[\delay] + TRand.ar(0, p[\scatter], trig)).clip(0, 1.5);
		var src = DelayC.ar(sig.sum * 0.5, 1.6, back);
		var rate = TRand.ar(p[\pitchJitter].neg, p[\pitchJitter], trig).midiratio;
		var shifted = PitchShift.ar(src, 0.1, rate, 0, 0.004);
		GrainIn.ar(2, trig, p[\grainDur], shifted, TRand.ar(p[\spread].neg, p[\spread], trig))
	});
