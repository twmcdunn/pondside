// ---- The kit: what every entry builds on.
//   ~lxFx[\name] = (defaults: (mix: 1, ...), func: { |sig, p| wet })   an effect: `sig` is
//       stereo, `p` holds a control per default (lagged 0.1 s), the result is the wet signal.
//   ~lxBuildFx.value   builds two SynthDefs per effect:
//       \lx_<name>        an insert on a pattern's bus (Pfx, Pfxb, ~lx[\withFx]): reads and
//                         replaces `out` (2 channels)
//       \lx_<name>_mono   on a mono source bus such as ~live: reads `in`, writes stereo to `out`
//     Both take mix (0 dry .. 1 wet), amp, gate and release (on gate 0 they keep processing
//     and fade over release s, so tails ring), and each of the effect's defaults.
//   ~lx[\name]   the pattern helpers.
~lxFx = ~lxFx ? ();
~lx = ~lx ? ();
~lxBuildFx = {
	~lxFx.keysValuesDo { |name, e|
		var body = { |sig|
			var p = (), mix = e[\defaults][\mix] ? 1;
			e[\defaults].keysValuesDo { |k, v| if(k != \mix) { p[k] = NamedControl.kr(k, v, 0.1) } };
			XFade2.ar(sig, e[\func].(sig, p), (NamedControl.kr(\mix, mix, 0.1) * 2) - 1) * NamedControl.kr(\amp, 1, 0.1)
		};
		SynthDef(("lx_" ++ name).asSymbol, { |out = 0, gate = 1, release = 2|
			var env = EnvGen.kr(Env.asr(0, 1, release.max(0.01), \lin), gate, doneAction: 2);
			ReplaceOut.ar(out, body.(In.ar(out, 2)) * env);
		}).add;
		SynthDef(("lx_" ++ name ++ "_mono").asSymbol, { |out = 0, in = 0, gate = 1, release = 2|
			var env = EnvGen.kr(Env.asr(0.05, 1, release.max(0.01), \lin), gate, doneAction: 2);
			Out.ar(out, body.(In.ar(in, 1) ! 2) * env);
		}).add;
	};
};
