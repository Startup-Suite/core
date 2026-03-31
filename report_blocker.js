const { Socket } = require('/Users/devbot/.openclaw/extensions/startup-suite-beacon/node_modules/phoenix/priv/static/phoenix.cjs');
const WebSocket = require('/Users/devbot/.openclaw/extensions/startup-suite-beacon/node_modules/ws');
globalThis.WebSocket = WebSocket;

const fs = require('fs');
const configData = JSON.parse(fs.readFileSync('/Users/devbot/.openclaw/openclaw.json', 'utf8'));
const acct = configData.channels['startup-suite'].accounts.builder; 

const config = {
  url: acct.url,
  runtimeId: acct.runtimeId || 'builder',
  token: acct.token,
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
    console.log("TOOL RESULT:", JSON.stringify(payload));
    channel.leave();
    socket.disconnect();
    process.exit(0);
  });

  channel.join()
    .receive('ok', () => {
      joined = true;
      const callId = `tc_${Date.now()}`;
      console.log("Joined, calling tool...");
      channel.push('tool_call', {
        call_id: callId,
        tool: 'report_blocker',
        args: {
          task_id: '019d4209-af0f-7892-bdee-e369252b2e52',
          stage_id: '019d4230-baf2-731a-9e5c-7ae346974c93',
          description: 'CI tests failed on PR 130. Deploy is blocked per instructions (do not attempt code fixes for feature code on deploy phase).'
        }
      });
    })
    .receive('error', (err) => { console.error("JOIN ERROR:", JSON.stringify(err)); process.exit(1); });
});

socket.connect();
setTimeout(() => { console.log('TIMEOUT'); process.exit(1); }, 12000);
