// Pondside — the score is the timing source; SuperCollider owns the clock.
//
//   p = Pondside("~/scores/piece", "score");    // reads score.cues, loads score.wav
//   p.on(\cue12, { |cue| ~swell.set(\amp, 0.5) });
//   p.play(from: "42:1");                         // bar 42, or seconds: p.play(from: 133.3)
//   p.stop;
//
// <name>.wav and <name>.cues (seconds<TAB>bar<TAB>cue N) are what `pondside mockup`
// writes beside the score, and the app runs it after every engraving: call p.load
// to pick up new times. Cue times come from the same compile as the mockup's MIDI,
// so the two cannot drift: the buffer and every cue are sent as bundles timestamped
// from one logical start time. (`pondside cues --format cues` writes the same lines.)

Pondside {
	var <dir, <name, <server, <rate, <cues, <handlers, <buffer, <synth, <routine, <startedAt;

	*new { |dir, name = "piece", rate = 48000, server|
		^super.new.init(dir.standardizePath, name, rate, server ? Server.default)
	}

	init { |argDir, argName, argRate, argServer|
		dir = argDir;
		name = argName;
		rate = argRate;
		server = argServer;
		handlers = IdentityDictionary.new;
		this.load;
	}

	cuesPath { ^dir +/+ (name ++ ".cues") }
	wavPath { ^dir +/+ (name ++ ".wav") }

	// Re-read the cue times (after the score changed and was re-exported).
	load {
		cues = if(File.exists(this.cuesPath)) {
			File.readAllString(this.cuesPath).split($\n)
				.reject { |l| l.stripWhiteSpace.isEmpty }
				.collect { |l|
					var f = l.split($\t), label = f[2] ? "", cueName = label.replace("cue ", "");
					(time: f[0].asFloat, bar: f[1].asInteger, label: label, name: cueName,
						handler: Pondside.handlerName(cueName))
				}
		} {
			"Pondside: no % — run `pondside cues <score.ly> --format cues --out %`"
				.format(this.cuesPath, this.cuesPath).warn;
			[]
		};
		"Pondside: % cues from %".format(cues.size, this.cuesPath.basename).postln;
	}

	// The same rule as Pondside's HandlerSync: "12" -> \cue12, "FxSwell" -> \fxSwell.
	*handlerName { |cueName|
		var s = cueName.collect { |c| if(c.isAlphaNum) { c } { $_ } };
		if(s.isEmpty) { ^\cue };
		if(s[0].isDecDigit) { ^("cue" ++ s).asSymbol };
		^(s[0].toLower.asString ++ s.drop(1)).asSymbol
	}

	on { |handler, func| handlers[handler.asSymbol] = func }

	// Cues with no handler, so the Cue Inspector's warning has an SC twin.
	unhandled { ^cues.reject { |c| handlers[c[\handler]].notNil } }

	// Seconds for "bar" or "bar:beat" (beats are not in piece.cues: a bar
	// starts at its first cue or later), or a number of seconds.
	secondsFor { |from|
		var bar;
		if(from.isNil) { ^0 };
		if(from.isNumber) { ^from };
		bar = from.asString.split($:)[0].asInteger;
		^(cues.detect { |c| c[\bar] >= bar } !? { |c| c[\time] } ? 0)
	}

	// Refuses to play at the wrong rate rather than transposing everything.
	checkRate {
		var actual = server.sampleRate;
		if(actual.isNil) { "Pondside: boot the server first".warn; ^false };
		if(actual.round != rate) {
			("Pondside: the server runs at % Hz but the mockup and cues are at % Hz.\n"
				++ "Fix: s.options.sampleRate = %; s.reboot;").format(actual, rate, rate).warn;
			^false
		};
		^true
	}

	play { |from, latency|
		var offset = this.secondsFor(from), lat = latency ? server.latency;
		if(this.checkRate.not) { ^this };
		this.stop;
		fork {
			if(File.exists(this.wavPath)) {
				buffer = Buffer.read(server, this.wavPath, (offset * rate).round.asInteger);
				server.sync;
			} {
				"Pondside: no mockup at % — cues only".format(this.wavPath).warn;
			};
			SynthDef(\pondsideMockup, { |out = 0, buf|
				Out.ar(out, PlayBuf.ar(2, buf, BufRateScale.kr(buf), doneAction: 2))
			}).add;
			server.sync;
			startedAt = thisThread.seconds;
			routine = Routine {
				var t = 0;
				if(buffer.notNil) {
					server.makeBundle(lat, { synth = Synth(\pondsideMockup, [\buf, buffer]) });
				};
				cues.select { |c| c[\time] >= offset }.do { |c|
					(c[\time] - offset - t).wait;
					t = c[\time] - offset;
					handlers[c[\handler]] !? { |f| server.makeBundle(lat, { f.value(c) }) } ?? {
						"Pondside: % at %s has no handler (p.on(\\%, { |cue| ... }))"
							.format(c[\label], c[\time].round(0.001), c[\handler]).postln;
					};
				};
			}.play(SystemClock);
		};
	}

	stop {
		routine !? (_.stop);
		synth !? (_.free);
		buffer !? (_.free);
		routine = synth = buffer = nil;
	}
}
