'use strict';
/*
 * replayd-encoder-introspect.js
 * ---------------------------------------------------------------------------
 * Observe (read-only) the video-encoder configuration that iOS ReplayKit uses
 * when recording the screen, to understand why output files are large.
 *
 * Target process : replayd   (the daemon that actually captures + encodes)
 * Platform       : jailbroken iOS, ARM64, Frida 17.x
 *
 * Run:
 *   frida -U -n replayd -l replayd-encoder-introspect.js
 *   # or spawn-on-launch is not useful here; replayd is already running, so attach.
 *   # If replayd respawns when recording starts, use: frida -U -W replayd -l ... (gating)
 *
 * What it reports:
 *   - VTCompressionSessionCreate  -> width, height, codec (FourCC), encoder spec
 *   - VTSessionSetProperty        -> every individual property key + value
 *   - VTSessionSetProperties      -> the whole property dictionary in one shot
 *   - AVAssetWriterInput init     -> the outputSettings dict (codec + bitrate + GOP)
 *   - AVAssetWriter init          -> output URL + file type
 *
 * Everything here is observe-only. No values are modified.
 */

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// Decode a CMVideoCodecType / FourCC integer into its 4-char string.
// e.g. 'avc1' (H.264), 'hvc1' (HEVC), 'jpeg', etc.
function fourCC(n) {
  n = n >>> 0;
  const s = String.fromCharCode((n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff);
  return `${s} (0x${n.toString(16)})`;
}

// Safely turn a CoreFoundation / Objective-C object pointer into a readable
// string. CFString/CFNumber/CFDictionary are toll-free bridged to NS* types,
// so the ObjC bridge can describe them.
function cfDescribe(p) {
  if (p === undefined || p === null || p.isNull()) return '(null)';
  try {
    const o = new ObjC.Object(p);
    // -description gives a multi-line dump for dictionaries; keep it readable.
    return o.toString();
  } catch (e) {
    return `<unreadable ${p}>`;
  }
}

function line() {
  console.log('---------------------------------------------------------------');
}

// ---------------------------------------------------------------------------
// VideoToolbox hooks  (the real encoder configuration)
// ---------------------------------------------------------------------------

function hookVideoToolbox() {
  const vt = Process.findModuleByName('VideoToolbox') ||
             Process.findModuleByName('VideoToolbox.framework');
  if (!vt) {
    console.log('[!] VideoToolbox not loaded yet. Will retry on demand.');
    return false;
  }

  // OSStatus VTCompressionSessionCreate(
  //   alloc, int32 width, int32 height, CMVideoCodecType codecType,
  //   CFDictionary encoderSpecification, CFDictionary srcImageBufferAttrs,
  //   alloc, callback, refcon, VTCompressionSessionRef *out)
  const createPtr = vt.findExportByName('VTCompressionSessionCreate');
  if (createPtr) {
    Interceptor.attach(createPtr, {
      onEnter(args) {
        line();
        console.log('[VTCompressionSessionCreate]');
        console.log('  width     :', args[1].toInt32());
        console.log('  height    :', args[2].toInt32());
        console.log('  codecType :', fourCC(args[3].toUInt32()));
        console.log('  encoderSpec        :', cfDescribe(args[4]));
        console.log('  srcImageBufferAttrs:', cfDescribe(args[5]));
        // Backtrace shows whether it's driven by AVAssetWriter or direct VT.
        try {
          console.log('  caller:', DebugSymbol.fromAddress(this.returnAddress).toString());
        } catch (e) {}
      }
    });
    console.log('[+] hooked VTCompressionSessionCreate');
  }

  // OSStatus VTSessionSetProperty(VTSessionRef, CFStringRef key, CFTypeRef value)
  const setPropPtr = vt.findExportByName('VTSessionSetProperty');
  if (setPropPtr) {
    Interceptor.attach(setPropPtr, {
      onEnter(args) {
        const key = cfDescribe(args[1]);
        const val = cfDescribe(args[2]);
        console.log(`[VTSessionSetProperty] ${key} = ${val}`);
      }
    });
    console.log('[+] hooked VTSessionSetProperty');
  }

  // OSStatus VTSessionSetProperties(VTSessionRef, CFDictionaryRef propertyDictionary)
  const setPropsPtr = vt.findExportByName('VTSessionSetProperties');
  if (setPropsPtr) {
    Interceptor.attach(setPropsPtr, {
      onEnter(args) {
        line();
        console.log('[VTSessionSetProperties] dictionary:');
        console.log(cfDescribe(args[1]));
      }
    });
    console.log('[+] hooked VTSessionSetProperties');
  }

  return !!(createPtr || setPropPtr || setPropsPtr);
}

// ---------------------------------------------------------------------------
// AVFoundation hooks  (file-writer level settings)
// ---------------------------------------------------------------------------

function hookAVFoundation() {
  if (!ObjC.available) {
    console.log('[!] ObjC runtime not available — skipping AVFoundation hooks.');
    return;
  }

  // - [AVAssetWriterInput initWithMediaType:outputSettings:]
  // outputSettings carries AVVideoCodecKey, AVVideoWidthKey, AVVideoHeightKey,
  // and AVVideoCompressionPropertiesKey -> { AVVideoAverageBitRateKey,
  // AVVideoMaxKeyFrameIntervalKey, AVVideoProfileLevelKey, ... }
  const inputCls = ObjC.classes.AVAssetWriterInput;
  if (inputCls) {
    const sel = '- initWithMediaType:outputSettings:';
    if (inputCls[sel]) {
      Interceptor.attach(inputCls[sel].implementation, {
        onEnter(args) {
          line();
          const mediaType = cfDescribe(args[2]);
          console.log('[AVAssetWriterInput init] mediaType:', mediaType);
          console.log('  outputSettings:', cfDescribe(args[3]));
        }
      });
      console.log('[+] hooked AVAssetWriterInput init');
    }

    // Sometimes apps go through the source-format variant.
    const sel2 = '- initWithMediaType:outputSettings:sourceFormatHint:';
    if (inputCls[sel2]) {
      Interceptor.attach(inputCls[sel2].implementation, {
        onEnter(args) {
          line();
          console.log('[AVAssetWriterInput init+hint] mediaType:', cfDescribe(args[2]));
          console.log('  outputSettings:', cfDescribe(args[3]));
        }
      });
      console.log('[+] hooked AVAssetWriterInput init (sourceFormatHint variant)');
    }
  }

  // - [AVAssetWriter initWithURL:fileType:error:]  -> where the file lands + container
  const writerCls = ObjC.classes.AVAssetWriter;
  if (writerCls && writerCls['- initWithURL:fileType:error:']) {
    Interceptor.attach(writerCls['- initWithURL:fileType:error:'].implementation, {
      onEnter(args) {
        line();
        console.log('[AVAssetWriter init] URL:', cfDescribe(args[2]));
        console.log('  fileType:', cfDescribe(args[3]));
      }
    });
    console.log('[+] hooked AVAssetWriter init');
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

console.log('=== replayd encoder introspection ===');
console.log('pid:', Process.id, 'arch:', Process.arch);

let vtHooked = hookVideoToolbox();
hookAVFoundation();

// VideoToolbox may not be loaded at attach time (it loads lazily when the first
// recording starts). Watch dlopen and hook it the moment it appears.
if (!vtHooked) {
  const dlopen = Module.getGlobalExportByName('dlopen');
  Interceptor.attach(dlopen, {
    onLeave() {
      if (!vtHooked && Process.findModuleByName('VideoToolbox')) {
        vtHooked = hookVideoToolbox();
      }
    }
  });
  console.log('[*] waiting for VideoToolbox to load (watching dlopen)...');
}

console.log('[*] ready — start a screen recording now.');
