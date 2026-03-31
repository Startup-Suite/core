const { Socket } = require('/Users/devbot/.openclaw/extensions/startup-suite-beacon/node_modules/phoenix/priv/static/phoenix.cjs');
const WebSocket = require('/Users/devbot/.openclaw/extensions/startup-suite-beacon/node_modules/ws');
globalThis.WebSocket = WebSocket;

const config = {
  url: 'wss://suite.milvenan.technology/runtime/ws',
  runtimeId: 'beacon-jordan-openclaw',
  token: 'DI8d7KAw9iXzkROVWvfENNy0i_DKoCrPmb-8zGbe45U',
};

const socket = new Socket(config.url, {
  params: { runtime_id: config.runtimeId, token: config.token },
  reconnectAfterMs: () => 999999999,
});

let joined = false;
socket.onOpen(() => {
  if (joined) return;
  const topic = `runtime:${config.runtimeId}`;
  const channel = socket.channel(topic, {});

  channel.on('tool_result', (payload) => {
    console.log(JSON.stringify(payload));
    channel.leave();
    socket.disconnect();
    process.exit(0);
  });

  channel.join()
    .receive('ok', () => {
      joined = true;
      const callId = `tc_${Date.now()}`;
      channel.push('tool_call', { 
        call_id: callId, 
        tool: 'validation_list', 
        args: { space_id: '019d40e0-c421-7976-8a83-9c3fd4074eba', task_id: '019d3fd3-0d95-70ba-ad86-271e7f06a759', stage_id: '019d40fc-f5d4-7e70-a7bb-f8c68cf7d0b5' } 
      });
    })
    .receive('error', (err) => { console.error(JSON.stringify(err)); process.exit(1); });
});

socket.connect();
setTimeout(() => { console.log('TIMEOUT'); process.exit(1); }, 5000);
