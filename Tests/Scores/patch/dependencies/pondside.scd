// Pondside's engine for invention. Pondside writes this file and keeps it current: don't edit it.
// The patch loads it with "dependencies/pondside.scd".loadRelative; then:
//   ~mode              \mockup: the mockup (../renders/invention.wav) is the live signal and the
//                      cues fire on time; \live: the mic, SoundIn.ar(0), and you fire each cue
//   ~cue[\cue12] = { |cue| … };   what happens at cue 12 (a routine: wait, fork, patterns)
//   ~live              the live signal's bus: effects on the performer read In.ar(~live)
//   ~triggerCue.()     cue 1 starts the piece; after that, the next cue
//   ~triggerCue.(12)   start at (or jump to) cue 12: the cues before it run at once
//   ~stop.()           stops the piece, and the routines and patterns its cues started
// A block whose first line is // @pondside live runs live only: Pondside's mix skips it.
(
var here = thisProcess.nowExecutingPath !? { |p| p.dirname } ? "", e;
~pondside = ~pondside ?? { IdentityDictionary.new };
e = ~pondside;
e[\renders] = here +/+ "../../renders";
e[\name] = "invention";
~mode = ~mode ? \mockup;
~cue = ~cue ? ();
~live = ~live ? Bus.audio(s, 1);
SynthDef(\pondsideMockup, { |buf, live, start = 0|
	var sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf), startPos: start * BufSampleRate.kr(buf), doneAction: 2);
	Out.ar(0, sig);
	Out.ar(live, sig.sum * 0.5);
}).add;
SynthDef(\pondsideMic, { |live| Out.ar(live, SoundIn.ar(0)) }).add;
// "12" -> \cue12, "FxSwell" -> \fxSwell, as Pondside names the handlers
e[\handler] = { |name|
	var n = name.collect { |c| if(c.isAlphaNum) { c } { $_ } };
	if(n[0].isDecDigit) { ("cue" ++ n).asSymbol } { n.copy.put(0, n[0].toLower).asSymbol }
};
// the cue list, [(time, bar, name, handler), …], from ../renders/<name>.cues
e[\cues] = {
	var path = e[\renders] +/+ e[\name] ++ ".cues";
	if(File.exists(path)) {
		File.readAllString(path).split($\n).reject(_.isEmpty).collect { |l|
			var f = l.split($\t), n = f[2].replace("cue ", "");
			(time: f[0].asFloat, bar: f[1].asInteger, name: n, handler: e[\handler].(n))
		}
	} { "no %: engrave the score in Pondside first".format(path).warn; [] }
};
// Required preparation belongs to the main waitForBoot routine.
e[\list] = e[\cues].value;
e[\buf] !? { e[\buf].free };
e[\buf] = if(~mode == \mockup) { Buffer.read(s, e[\renders] +/+ e[\name] ++ ".wav") };
e[\fire] = { |c| ("cue " ++ c.name).postln; ~cue[c.handler] !? { |f| f.value(c) } };
e[\fireNow] = { |c| fork { e[\fire].(c) } };   // a routine: a cue may wait
// plays from `from` seconds on the score's clock (beats = seconds); in mockup mode the
// cues from there on fire on time
e[\play] = { |from|
	e[\clock] = ~renderClock ?? { TempoClock(1, from).permanent_(true) };   // Pondside's mix brings its own
	e[\mainClock] = TempoClock.default;
	TempoClock.default = e[\clock];         // fork/wait and patterns in cues run on it
	CmdPeriod.doOnce { e[\src] = nil; ~stop.() };
	e[\src] = if(~mode == \live) { Synth(\pondsideMic, [\live, ~live]) }
		{ Synth(\pondsideMockup, [\buf, e[\buf], \live, ~live, \start, from]) };
	if(~mode == \mockup) { e[\list].do { |c, i| if(c.time >= from) {
		e[\clock].schedAbs(c.time, { e[\index] = max(e[\index], i + 1); e[\fireNow].(c); nil }) } } };
	"% from % s".format(~mode, from).postln;
};
// starts the piece at cue i (0: from the start): the cues before it run at once
e[\start] = { |i|
	~stop.();
	fork {
		var from = if(i > 0 and: { i < e[\list].size }) { e[\list][i].time } { 0 };
		s.sync;
		e[\index] = 0;
		e[\list].do { |c, j| if(c.time < from) { e[\fireNow].(c); e[\index] = j + 1 } };
		if(~mode == \live and: { i < e[\list].size }) { e[\index] = i + 1; e[\fireNow].(e[\list][i]) };
		e[\play].(from);
	};
};
~triggerCue = { |cue|
	var list = e[\list] ?? { e[\list] = e[\cues].value }, i;
	e[\index] = e[\index] ? 0;
	i = if(cue.isNil) { e[\index] } { list.detectIndex { |c| c.name == cue.asString or: { c.handler == cue } } };
	case
	{ i.isNil } { "no cue %".format(cue).postln }
	// not playing, or in mockup mode: (re)start there
	{ e[\clock].isNil or: { ~mode == \mockup } } { e[\start].(if(e[\clock].isNil and: { cue.isNil }) { 0 } { i }) }
	{ i >= list.size } { "no cue left (~stop.() ends the piece)".postln }
	{
		// live: the cues not run since the last one, at once, then this one
		if(i > e[\index]) { (e[\index]..(i - 1)).do { |j| e[\fireNow].(list[j]) } };
		e[\index] = i + 1;
		e[\fireNow].(list[i]);
	}
};
~stop = {
	e[\clock] !? { |c| TempoClock.default = e[\mainClock]; c.clear; SystemClock.sched(0, { c.stop; nil }) };
	e[\clock] = nil;
	e[\src] !? { e[\src].free };
	e[\src] = nil;
};
)
