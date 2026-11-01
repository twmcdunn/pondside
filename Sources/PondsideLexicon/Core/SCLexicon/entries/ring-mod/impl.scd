~lxFx[\ringMod] = (defaults: (mix: 1, freq: 300),
	func: { |sig, p| sig * SinOsc.ar(p[\freq]) });
