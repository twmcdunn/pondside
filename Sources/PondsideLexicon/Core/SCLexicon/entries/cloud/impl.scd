~lx[\cloud] = { |pcs, density = 10, amp = 0.05, lo = 60, hi = 96, length = 0.05, instrument = \lx_grain|
	Pbind(
		\instrument, instrument,
		\midinote, Pxrand(~lx[\pitches].(pcs, lo, hi), inf),
		\dur, (1 / density) * Pexprand(0.5, 2),
		\sustain, Pwhite(length * 0.5, length * 1.5),
		\amp, amp * Pwhite(0.5, 1),
		\pan, Pwhite(-0.8, 0.8)
	)
};
