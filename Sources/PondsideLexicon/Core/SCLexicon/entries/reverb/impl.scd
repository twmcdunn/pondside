~lxFx[\reverb] = (defaults: (mix: 0.3, room: 0.8, damp: 0.5),
	func: { |sig, p| FreeVerb2.ar(sig[0], sig[1], 1, p[\room].clip(0, 1), p[\damp].clip(0, 1)) });
