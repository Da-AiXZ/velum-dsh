"use strict";
// WebAssembly polyfill for --jitless Node.js environments.
// Provides a pure JS implementation of the llhttp HTTP response parser
// that undici uses via WebAssembly. This allows undici-based libraries
// (MCP servers, node-fetch, etc.) to work without real WebAssembly support.

if (typeof globalThis.WebAssembly === "undefined") {

// llhttp state machine states
const S_START = 0, S_RES_H = 1, S_RES_LINE = 2, S_STATUS = 3,
      S_HEADER_FIELD = 4, S_HEADER_VALUE = 5, S_HEADERS_DONE = 6,
      S_BODY_IDENTITY = 7, S_BODY_CHUNKED_SIZE = 8, S_BODY_CHUNKED_DATA = 9,
      S_BODY_CHUNKED_END = 10, S_COMPLETE = 11, S_DEAD = 12, S_PAUSED = 13,
      S_BODY_CHUNKED_CRLF = 14;

const OK = 0, INVALID_EOF_STATE = 14, PAUSED = 21, PAUSED_UPGRADE = 22;

// Simulated WebAssembly.Memory as a growable ArrayBuffer
const INITIAL_MEM = 1024 * 1024; // 1MB
let memBuf = new ArrayBuffer(INITIAL_MEM);
let memU8 = new Uint8Array(memBuf);
const memory = {
  buffer: memBuf,
  grow(pages) {
    const newSize = memBuf.byteLength + pages * 65536;
    const newBuf = new ArrayBuffer(newSize);
    new Uint8Array(newBuf).set(memU8);
    memBuf = newBuf;
    memU8 = new Uint8Array(memBuf);
    memory.buffer = memBuf;
  }
};

// Simple bump allocator for wasm memory simulation
let heapPtr = 4096; // start after null page
function walloc(size) {
  const aligned = (size + 7) & ~7;
  if (heapPtr + aligned > memBuf.byteLength) {
    memory.grow(Math.ceil(aligned / 65536) + 1);
  }
  const ptr = heapPtr;
  heapPtr += aligned;
  return ptr;
}

// Parser instance storage (indexed by pointer)
const parsers = new Map();
let nextParserId = 8192;

// Callbacks from the env object - will be set by undici when instantiating
let envCallbacks = {};

function createParser(type) {
  const id = nextParserId;
  nextParserId += 256; // space between parsers
  parsers.set(id, {
    type, // 1=REQUEST, 2=RESPONSE
    state: S_START,
    statusCode: 0,
    upgrade: false,
    shouldKeepAlive: true,
    contentLength: -1,
    chunked: false,
    remaining: 0,
    chunkSize: 0,
    headersDone: false,
    crlfHalf: false,
    pending: null,
    errorReason: 0,
    errorReasonPtr: 0,
    errorPos: 0,
    paused: false
  });
  return id;
}

// Write a C string into wasm memory, return pointer
function writeStr(str) {
  const ptr = walloc(str.length + 1);
  for (let i = 0; i < str.length; i++) memU8[ptr + i] = str.charCodeAt(i);
  memU8[ptr + str.length] = 0;
  return ptr;
}

function completeMessage(p, ptr) {
  const rc = envCallbacks.wasm_on_message_complete(ptr);
  p.state = S_START; // ready for next message (keep-alive)
  p.statusCode = 0;
  p.upgrade = false;
  p.shouldKeepAlive = true;
  p.contentLength = -1;
  p.chunked = false;
  p.remaining = 0;
  p.chunkSize = 0;
  p.headersDone = false;
  p.crlfHalf = false;
  p.pending = null;
  return rc;
}

// Parse HTTP response data
function llhttp_execute(ptr, bufPtr, bufLen) {
  const p = parsers.get(ptr);
  if (!p) return 1; // INTERNAL error
  if (p.paused) return PAUSED;

  // Prepend bytes left over from a previous partial line. Undici reuses the
  // same malloc'd buffer, so shifting the incoming chunk right keeps every
  // callback pointer consistent with currentBufferPtr.
  if (p.pending && p.pending.length > 0) {
    const pending = p.pending;
    memU8.copyWithin(bufPtr + pending.length, bufPtr, bufPtr + bufLen);
    memU8.set(pending, bufPtr);
    bufLen += pending.length;
    p.pending = null;
  }

  const data = new Uint8Array(memory.buffer, bufPtr, bufLen);
  let i = 0;

  const keepTail = (from) => {
    p.pending = new Uint8Array(data.subarray(from, bufLen));
  };

  while (i < bufLen) {
    switch (p.state) {
      case S_START: {
        // Look for "HTTP/"
        if (data[i] === 0x48) { // 'H'
          p.state = S_RES_H;
        } else {
          i++;
        }
        break;
      }

      case S_RES_H: {
        // Scan for end of status line (first \r\n)
        const lineEnd = findCRLF(data, i, bufLen);
        if (lineEnd === -1) { keepTail(i); p.errorPos = bufPtr + bufLen; return OK; } // need more data

        // Parse "HTTP/x.x SSS Reason"
        const line = decodeAscii(data, i, lineEnd); // i still points at 'H'
        const match = line.match(/^HTTP\/\d\.\d\s+(\d{3})\s*(.*)/);
        if (match) {
          p.statusCode = parseInt(match[1], 10);
          // Notify status
          const statusStart = bufPtr + i + line.indexOf(match[2]);
          const statusLen = match[2].length;
          let rc = envCallbacks.wasm_on_message_begin(ptr);
          if (rc) { p.errorPos = bufPtr + i; return rc; }
          if (statusLen > 0) {
            rc = envCallbacks.wasm_on_status(ptr, bufPtr + i + line.indexOf(match[1]) + match[1].length + 1, statusLen);
            if (rc) { p.errorPos = bufPtr + i; return rc; }
          }
        }
        i = lineEnd + 2; // skip \r\n
        p.state = S_HEADER_FIELD;
        p.chunked = false;
        p.contentLength = -1;
        p.upgrade = false;
        p.shouldKeepAlive = true;
        break;
      }

      case S_HEADER_FIELD: {
        // Check for end of headers (\r\n)
        if (data[i] === 0x0d) {
          if (i + 1 < bufLen && data[i + 1] === 0x0a) {
            i += 2;
            p.state = S_HEADERS_DONE;
            break;
          }
          if (i + 1 >= bufLen) { keepTail(i); p.errorPos = bufPtr + bufLen; return OK; }
        }
        // Wait until the whole header line (colon + value + CRLF) is present
        // before emitting anything, so a TCP split never repeats a callback.
        const colonIdx = findByte(data, 0x3a, i, bufLen);
        if (colonIdx === -1) { keepTail(i); p.errorPos = bufPtr + bufLen; return OK; }
        const valEnd = findCRLF(data, colonIdx + 1, bufLen);
        if (valEnd === -1) { keepTail(i); p.errorPos = bufPtr + bufLen; return OK; }

        const fieldStart = bufPtr + i;
        const fieldLen = colonIdx - i;
        const rc = envCallbacks.wasm_on_header_field(ptr, fieldStart, fieldLen);
        if (rc) { p.errorPos = bufPtr + i; return rc; }

        // Track transfer-encoding and content-length
        const fieldName = decodeAscii(data, i, colonIdx).toLowerCase();
        let vi = colonIdx + 1;
        while (vi < valEnd && data[vi] === 0x20) vi++;

        const valueStart = bufPtr + vi;
        const valueLen = valEnd - vi;
        const rc2 = envCallbacks.wasm_on_header_value(ptr, valueStart, valueLen);
        if (rc2) { p.errorPos = bufPtr + vi; return rc2; }

        const value = decodeAscii(data, vi, valEnd).toLowerCase().trim();
        if (fieldName === "transfer-encoding" && value.includes("chunked")) p.chunked = true;
        if (fieldName === "content-length") p.contentLength = parseInt(value, 10);
        if (fieldName === "connection" && value === "close") p.shouldKeepAlive = false;
        if (fieldName === "upgrade") p.upgrade = true;

        i = valEnd + 2;
        break;
      }

      case S_HEADERS_DONE: {
        let rc = 0;
        if (!p.headersDone) {
          rc = envCallbacks.wasm_on_headers_complete(ptr, p.statusCode,
            p.upgrade ? 1 : 0, p.shouldKeepAlive ? 1 : 0);
          if (rc === 1) {
            // skip body (HEAD)
            p.headersDone = true;
            p.state = S_COMPLETE;
            break;
          }
          if (rc === 2) {
            p.upgrade = true;
            p.errorPos = bufPtr + i;
            return PAUSED_UPGRADE;
          }
          if (rc !== 0 && rc !== PAUSED) { p.errorPos = bufPtr + i; return rc; }

          p.headersDone = true;
          if (p.upgrade) {
            p.errorPos = bufPtr + i;
            return PAUSED_UPGRADE;
          }

          if (p.chunked) {
            p.state = S_BODY_CHUNKED_SIZE;
          } else if (p.contentLength > 0) {
            p.state = S_BODY_IDENTITY;
            p.remaining = p.contentLength;
          } else if (p.contentLength === 0) {
            p.state = S_COMPLETE;
          } else {
            // No content-length, no chunked: read until close (for responses)
            // or no body (for 1xx, 204, 304)
            if (p.statusCode === 204 || p.statusCode === 304 || (p.statusCode >= 100 && p.statusCode < 200)) {
              p.state = S_COMPLETE;
            } else {
              p.state = S_BODY_IDENTITY;
              p.remaining = Infinity;
            }
          }
          if (rc === PAUSED) { p.errorPos = bufPtr + i; return rc; }
        }
        break;
      }

      case S_BODY_IDENTITY: {
        const available = bufLen - i;
        const toConsume = p.remaining === Infinity ? available : Math.min(available, p.remaining);
        if (toConsume > 0) {
          const rc = envCallbacks.wasm_on_body(ptr, bufPtr + i, toConsume);
          if (rc) { p.errorPos = bufPtr + i; return rc; }
          i += toConsume;
          if (p.remaining !== Infinity) p.remaining -= toConsume;
        }
        if (p.remaining === 0) {
          p.state = S_COMPLETE;
          break;
        }
        if (i >= bufLen) { p.errorPos = bufPtr + i; return OK; }
        break;
      }

      case S_BODY_CHUNKED_SIZE: {
        const lineEnd = findCRLF(data, i, bufLen);
        if (lineEnd === -1) { keepTail(i); p.errorPos = bufPtr + bufLen; return OK; }
        const sizeStr = decodeAscii(data, i, lineEnd).replace(/;.*/, "").trim();
        p.chunkSize = parseInt(sizeStr, 16);
        if (!Number.isFinite(p.chunkSize) || p.chunkSize < 0) {
          p.errorPos = bufPtr + i;
          return 12; // INVALID_CHUNK_SIZE
        }
        i = lineEnd + 2;
        if (p.chunkSize === 0) {
          p.state = S_BODY_CHUNKED_END;
        } else {
          p.state = S_BODY_CHUNKED_DATA;
          p.remaining = p.chunkSize;
        }
        break;
      }

      case S_BODY_CHUNKED_DATA: {
        const available = bufLen - i;
        const toConsume = Math.min(available, p.remaining);
        if (toConsume > 0) {
          const rc = envCallbacks.wasm_on_body(ptr, bufPtr + i, toConsume);
          if (rc) { p.errorPos = bufPtr + i; return rc; }
          i += toConsume;
          p.remaining -= toConsume;
        }
        if (p.remaining === 0) {
          p.state = S_BODY_CHUNKED_CRLF;
          p.crlfHalf = false;
        }
        if (i >= bufLen) { p.errorPos = bufPtr + i; return OK; }
        break;
      }

      case S_BODY_CHUNKED_CRLF: {
        if (p.crlfHalf) {
          if (i >= bufLen) { p.errorPos = bufPtr + i; return OK; }
          if (data[i] === 0x0a) {
            i++;
            p.crlfHalf = false;
            p.state = S_BODY_CHUNKED_SIZE;
            break;
          }
          p.errorPos = bufPtr + i;
          return 1;
        }
        if (i >= bufLen) { p.errorPos = bufPtr + i; return OK; }
        if (data[i] === 0x0d) {
          if (i + 1 < bufLen) {
            if (data[i + 1] === 0x0a) {
              i += 2;
              p.state = S_BODY_CHUNKED_SIZE;
              break;
            }
            p.errorPos = bufPtr + i;
            return 1;
          }
          p.crlfHalf = true;
          p.errorPos = bufPtr + i;
          return OK;
        }
        p.errorPos = bufPtr + i;
        return 1;
      }

      case S_BODY_CHUNKED_END: {
        // After the 0-size chunk: an empty line ends the body; anything else
        // is a trailer line to skip.
        if (i + 1 < bufLen && data[i] === 0x0d && data[i + 1] === 0x0a) {
          i += 2;
          p.state = S_COMPLETE;
          break;
        }
        const lineEnd = findCRLF(data, i, bufLen);
        if (lineEnd === -1) { keepTail(i); p.errorPos = bufPtr + bufLen; return OK; }
        i = lineEnd + 2;
        break;
      }

      case S_COMPLETE: {
        const rc = completeMessage(p, ptr);
        if (rc) { p.errorPos = bufPtr + i; return rc; }
        p.errorPos = bufPtr + i;
        return OK;
      }

      default:
        p.errorPos = bufPtr + i;
        return 1; // INTERNAL
    }
    if (p.state === S_COMPLETE && i >= bufLen) {
      const rc = completeMessage(p, ptr);
      if (rc) { p.errorPos = bufPtr + i; return rc; }
    }
  }

  p.errorPos = bufPtr + bufLen;
  return OK;
}

function findCRLF(data, from, to) {
  for (let j = from; j < to - 1; j++) {
    if (data[j] === 0x0d && data[j + 1] === 0x0a) return j;
  }
  return -1;
}

function findByte(data, byte, from, to) {
  for (let j = from; j < to; j++) {
    if (data[j] === byte) return j;
  }
  return -1;
}

function decodeAscii(data, from, to) {
  let s = "";
  for (let j = from; j < to; j++) s += String.fromCharCode(data[j]);
  return s;
}

// Build the fake WebAssembly module exports
const wasmExports = {
  memory,
  llhttp_alloc(type) { return createParser(type); },
  llhttp_free(ptr) { parsers.delete(ptr); },
  llhttp_execute,
  llhttp_finish(ptr) {
    const p = parsers.get(ptr);
    if (!p) return 1;
    // A close-delimited body legitimately ends at EOF; everything else that
    // still expects bytes is a protocol error.
    if (p.state === S_COMPLETE || p.state === S_START) return OK;
    if (p.state === S_BODY_IDENTITY && p.remaining === Infinity) {
      p.state = S_COMPLETE;
      return OK;
    }
    p.errorPos = 0;
    if (!p.errorReasonPtr) p.errorReasonPtr = writeStr("invalid EOF state");
    return INVALID_EOF_STATE;
  },
  llhttp_resume(ptr) {
    const p = parsers.get(ptr);
    if (p) p.paused = false;
  },
  llhttp_get_error_pos(ptr) {
    const p = parsers.get(ptr);
    return p ? p.errorPos : 0;
  },
  llhttp_get_error_reason(ptr) {
    const p = parsers.get(ptr);
    if (!p) return 0;
    if (!p.errorReasonPtr) p.errorReasonPtr = writeStr("OK");
    return p.errorReasonPtr;
  },
  malloc(size) { return walloc(size); },
  free(ptr) { /* bump allocator, no-op */ }
};

// Create a fake compiled WebAssembly module token
const fakeModule = Symbol("llhttp-js-module");

function captureImports(importObj) {
  if (importObj && importObj.env) envCallbacks = importObj.env;
}

globalThis.WebAssembly = {
  async compile(bytes) { return new WebAssembly.Module(bytes); },
  async instantiate(modOrBytes, importObj) {
    captureImports(importObj);
    const mod = modOrBytes instanceof WebAssembly.Module ? modOrBytes : new WebAssembly.Module(modOrBytes);
    const instance = new WebAssembly.Instance(mod, importObj);
    return { module: mod, instance };
  },
  Module: function(bytes) {
    this._bytes = bytes;
    this._fakeLlhttp = true;
  },
  Instance: function(mod, importObj) {
    captureImports(importObj);
    this.module = mod;
    this.exports = wasmExports;
  },
  Memory: function(desc) {
    return memory;
  },
  Table: function() {},
  validate(bytes) { return true; },
  compileStreaming() { return Promise.resolve(new WebAssembly.Module(null)); },
  instantiateStreaming(source, importObj) {
    captureImports(importObj);
    const mod = new WebAssembly.Module(null);
    return Promise.resolve({ module: mod, instance: new WebAssembly.Instance(mod, importObj) });
  }
};

} // end if WebAssembly undefined
