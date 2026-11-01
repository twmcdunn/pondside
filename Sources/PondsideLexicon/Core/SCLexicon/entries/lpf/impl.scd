~lxFx[\lpf] = (defaults: (mix: 1, freq: 2000, rq: 0.7),
	func: { |sig, p| RLPF.ar(sig, p[\freq].clip(20, 20000), p[\rq].clip(0.05, 2)) });
