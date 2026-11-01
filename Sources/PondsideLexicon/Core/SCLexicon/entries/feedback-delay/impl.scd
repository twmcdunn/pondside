~lxFx[\fbDelay] = (defaults: (mix: 0.4, time: 0.375, fb: 0.5, damp: 5000),
	func: { |sig, p|
		var loop = LocalIn.ar(2), wet;
		wet = DelayC.ar(sig + (loop * p[\fb]), 4, (p[\time] - ControlDur.ir).clip(0, 4));
		LocalOut.ar(LPF.ar(wet, p[\damp].clip(20, 20000)).clip2(4));
		wet
	});
