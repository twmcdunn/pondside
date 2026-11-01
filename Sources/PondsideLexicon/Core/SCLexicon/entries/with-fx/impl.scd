~lx[\withFx] = { |pattern, effects, tail = 2|
	Pchain(effects.inject(pattern) { |pat, e|
		Pfxb(pat, ("lx_" ++ e[0]).asSymbol, *((e[1] ? ()).asKeyValuePairs ++ [\release, tail.max(0.05)]))
	}, (endTime: tail.max(0.05)))
};
