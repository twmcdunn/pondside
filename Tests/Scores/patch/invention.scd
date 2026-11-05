// @pondside patch for invention.ly. Execute the main block once; then ~triggerCue.() fires each live cue.
// @pondside init v2
(
var patchFile = thisProcess.nowExecutingPath, patchFolder, prepare;
patchFolder = patchFile.dirname;
s.options.memSize = 262144;
s.options.numWireBufs = 1024;
prepare = {
s.waitForBoot({
thisProcess.nowExecutingPath = patchFile;
~mode = ~pondsideMode ? \live; // \live or \mockup; the renderer/exporter may override it.
~resources = patchFolder +/+ "resources";
~sharedSounds = Platform.userAppSupportDir +/+ "sounds";
(patchFolder +/+ "dependencies/pondside.scd").load;
// @pondside cues

s.sync;
"PONDSIDE_PREPARED".postln;
});
};
// reboot's callback runs while the server is off, so preparation can
// never run against the server that is about to be replaced.
if(~renderClock.notNil) { prepare.value } { s.reboot(prepare) };
)
// After the main block is ready: ~triggerCue.();  // next live cue
// ~triggerCue.(12);  // jump to cue 12
// ~stop.();
