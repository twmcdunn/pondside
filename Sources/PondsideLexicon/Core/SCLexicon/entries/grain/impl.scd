SynthDef(\lx_grain, { |out = 0, freq = 440, amp = 0.1, sustain = 0.05, pan = 0, attack = 0.3|
	var env = EnvGen.ar(Env.perc(attack * sustain, (1 - attack) * sustain), doneAction: 2);
	Out.ar(out, Pan2.ar(SinOsc.ar(freq) * env * amp, pan));
}).add;
