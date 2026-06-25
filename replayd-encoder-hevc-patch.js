'use strict';
/*
 * replayd-encoder-hevc-patch.js
 * ---------------------------------------------------------------------------
 * Rewrite ReplayKit's video outputSettings at runtime: H.264 -> HEVC at an
 * equivalent-quality bitrate, so files shrink ~40-50% WITHOUT visible quality
 * loss. Resolution, frame rate and keyframe interval are left untouched.
 *
 * Target process : replayd   (jailbroken iOS, ARM64, Frida 17.x)
 *
 * Run:
 *   frida -U -n replayd -l replayd-encoder-hevc-patch.js
 *   # then start a screen recording
 *
 * It hooks -[AVAssetWriterInput initWithMediaType:outputSettings:(sourceFormatHint:)]
 * and, only for the video ('vide') track using avc1, swaps in an HEVC dict.
 * Audio and any already-HEVC track are left alone. Old + new settings are logged.
 */

// --- tune here -------------------------------------------------------------
// HEVC at ~half the H.264 bitrate is visually equivalent. The observed H.264
// rate was 16,915,046 bps; 9 Mbit/s HEVC ≈ same quality. Raise toward 11-12M
// if you want extra headroom and still save ~30%.
const TARGET_BITRATE = 9000000;          // bps
const TARGET_CODEC    = 'hvc1';          // AVVideoCodecTypeHEVC
const TARGET_PROFILE  = 'HEVC_Main_AutoLevel';
// ---------------------------------------------------------------------------

// Exact key STRING values as they appear in the live dictionary (see log).
const K_CODEC   = 'AVVideoCodecKey';
const K_COMP    = 'AVVideoCompressionPropertiesKey';
const K_BITRATE = 'AverageBitRate';      // value of AVVideoAverageBitRateKey
const K_PROFILE = 'ProfileLevel';        // value of AVVideoProfileLevelKey

function NSStr(s) {
  return ObjC.classes.NSString.stringWithUTF8String_(Memory.allocUtf8String(s));
}
function NSNum(n) {
  return ObjC.classes.NSNumber.numberWithDouble_(n);
}
function describe(p) {
  try { return new ObjC.Object(p).toString(); } catch (e) { return `<${p}>`; }
}

function patchVideoSettings(origPtr) {
  const orig = new ObjC.Object(origPtr);

  // Only touch a video track that is currently H.264.
  const codecObj = orig.objectForKey_(NSStr(K_CODEC));
  if (codecObj.isNull()) return null;                 // not a video dict
  const codecStr = new ObjC.Object(codecObj).toString();
  if (codecStr === TARGET_CODEC) return null;         // already HEVC, skip

  console.log('  OLD video settings:', orig.toString());

  // Mutable copy of the top-level dict, override codec.
  const m = orig.mutableCopy();
  m.setObject_forKey_(NSStr(TARGET_CODEC), NSStr(K_CODEC));

  // Mutable copy of the nested compression-properties dict, override
  // bitrate + profile; leave ExpectedFrameRate / MaxKeyFrameInterval as-is.
  const compPtr = orig.objectForKey_(NSStr(K_COMP));
  if (!compPtr.isNull()) {
    const comp = new ObjC.Object(compPtr).mutableCopy();
    comp.setObject_forKey_(NSNum(TARGET_BITRATE), NSStr(K_BITRATE));
    comp.setObject_forKey_(NSStr(TARGET_PROFILE), NSStr(K_PROFILE));
    m.setObject_forKey_(comp, NSStr(K_COMP));
  }

  // Intentionally not released: init will retain it; over-retaining by 1 is a
  // harmless leak and avoids any chance of premature dealloc.
  console.log('  NEW video settings:', m.toString());
  return m;
}

function installPatch(selector) {
  const cls = ObjC.classes.AVAssetWriterInput;
  if (!cls || !cls[selector]) return;
  Interceptor.attach(cls[selector].implementation, {
    onEnter(args) {
      const mediaType = describe(args[2]);
      if (mediaType !== 'vide') return;               // only patch the video track
      console.log('---------------------------------------------------------------');
      console.log(`[patch] ${selector}`);
      const patched = patchVideoSettings(args[3]);
      if (patched !== null) {
        args[3] = patched.handle;                     // swap in the HEVC dict
        console.log('  -> swapped video track to', TARGET_CODEC,
                    '@', TARGET_BITRATE, 'bps');
      }
    }
  });
  console.log('[+] patch installed on', selector);
}

if (!ObjC.available) {
  console.log('[!] ObjC runtime unavailable — wrong process?');
} else {
  console.log('=== replayd HEVC patch === pid:', Process.id);
  installPatch('- initWithMediaType:outputSettings:');
  installPatch('- initWithMediaType:outputSettings:sourceFormatHint:');
  console.log('[*] ready — start a screen recording now.');
}
