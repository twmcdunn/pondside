~lx[\density] = { |from = 2, to = 20, secs = 10, jitter = 0.3|
	(1 / ~lx[\glide].(from, to, secs, \exp)) * Pwhite(1 - jitter, 1 + jitter)
};
