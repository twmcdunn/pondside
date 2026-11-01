~lxFx[\drive] = (defaults: (mix: 1, gain: 4, tone: 6000),
	func: { |sig, p| LPF.ar((sig * p[\gain]).tanh, p[\tone].clip(200, 20000)) / p[\gain].max(1).sqrt });
