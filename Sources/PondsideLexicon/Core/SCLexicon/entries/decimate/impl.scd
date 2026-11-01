~lxFx[\decimate] = (defaults: (mix: 1, factor: 4, antiAlias: 0, antiImage: 0),
	func: { |sig, p|
		var newRate = SampleRate.ir / p[\factor].max(1);
		var lowPass = { |x| 2.do { x = LPF.ar(x, newRate / 4) }; x };
		var wet = SelectX.ar(p[\antiAlias].clip(0, 1), [sig, lowPass.(sig)]);
		wet = Latch.ar(wet, Impulse.ar(newRate / 2));
		SelectX.ar(p[\antiImage].clip(0, 1), [wet, lowPass.(wet)])
	});
