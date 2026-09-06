import init, {
  df_create,
  df_free,
  df_get_frame_length,
  df_process_frame,
  df_set_atten_lim,
  df_set_post_filter_beta,
} from './df.js';

const states = new Set();
let initializing;

/**
 * Processes messages shaped as `{ id, type, ... }` and replies with the same
 * `id`. `process` transfers its output buffer back to the caller.
 */
self.onmessage = async ({ data }) => {
  const { id, type } = data;

  try {
    switch (type) {
      case 'initialize': {
        await initialize();
        const state = df_create(asUint8Array(data.modelBytes), data.attenLimitDb);
        states.add(state);
        respond(id, 'ready', {
          state,
          frameLength: df_get_frame_length(state),
        });
        break;
      }
      case 'process': {
        ensureState(data.state);
        const output = df_process_frame(data.state, asFloat32Array(data.frame));
        respond(id, 'result', { frame: output }, [output.buffer]);
        break;
      }
      case 'setAttenuationLimit':
        ensureState(data.state);
        df_set_atten_lim(data.state, data.limitDb);
        respond(id, 'result');
        break;
      case 'setPostFilterBeta':
        ensureState(data.state);
        df_set_post_filter_beta(data.state, data.beta);
        respond(id, 'result');
        break;
      case 'dispose':
        ensureState(data.state);
        df_free(data.state);
        states.delete(data.state);
        respond(id, 'result');
        break;
      default:
        throw new Error(`Unknown DeepFilterNet worker command: ${type}`);
    }
  } catch (error) {
    respond(id, 'error', {
      message: error instanceof Error ? error.message : String(error),
      stack: error instanceof Error ? error.stack : undefined,
    });
  }
};

function initialize() {
  return initializing ??= init();
}

function ensureState(state) {
  if (!states.has(state)) {
    throw new Error('DeepFilterNet state is invalid or has been disposed.');
  }
}

function asUint8Array(value) {
  return value instanceof Uint8Array ? value : new Uint8Array(value);
}

function asFloat32Array(value) {
  return value instanceof Float32Array ? value : new Float32Array(value);
}

function respond(id, type, values = {}, transfer = []) {
  self.postMessage({ id, type, ...values }, transfer);
}
