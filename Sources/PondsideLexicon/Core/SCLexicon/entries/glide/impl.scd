~lx[\glide] = { |from = 0, to = 1, secs = 10, curve = 0|
	Pseq([Pseg(Pseq([from, to]), Pseq([secs]), curve), Pn(to, inf)])
};
