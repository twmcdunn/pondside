~lxFx[\tail] = (defaults: (mix: 0.5, rt60: 3, damp: 8000),
	func: { |sig, p|
		var delays = [0.0497, 0.0671, 0.0813, 0.0977];
		var hadamard = [[1, 1, 1, 1], [1, -1, 1, -1], [1, 1, -1, -1], [1, -1, -1, 1]];
		var src = sig.sum * 0.5, fb = LocalIn.ar(4), lines;
		[0.0043, 0.0067, 0.0097, 0.0131].do { |t| src = AllpassN.ar(src, 0.02, t, 0.3) };
		lines = hadamard.collect { |row| (row * fb).sum * 0.5 };
		lines = lines + (src * [1, -1, 1, -1] * 0.5);
		lines = DelayN.ar(lines, 0.2, delays - ControlDur.ir);
		lines = LPF.ar(lines, p[\damp].clip(20, 20000)) * (0.001 ** (delays / p[\rt60].max(0.05)));
		LocalOut.ar(lines.clip2(4));
		Splay.ar(LeakDC.ar(lines), 0.8)
	});
