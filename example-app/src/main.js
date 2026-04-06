
import './style.css';
import { CapacitorUpdater } from '@capgo/capacitor-updater';

const plugin = CapacitorUpdater;
const actions = [
  {
    id: 'notify-app-ready',
    label: 'Notify app ready',
    buttonLabel: 'Run notifyAppReady',
    description: 'Confirm that the current bundle booted successfully.',
    inputs: [],
    run: async () => {
      await plugin.notifyAppReady();
      return 'notifyAppReady() resolved.';
    },
  },
  {
    id: 'current-bundle',
    label: 'Get current bundle',
    buttonLabel: 'Run get current bundle',
    description: 'Read the active bundle and builtin native version.',
    inputs: [],
    run: async () => plugin.current(),
  },
  {
    id: 'list-bundles',
    label: 'List downloaded bundles',
    buttonLabel: 'Run list downloaded bundles',
    description: 'Inspect bundles currently stored on the device.',
    inputs: [],
    run: async () => plugin.list(),
  },
  {
    id: 'get-plugin-version',
    label: 'Get plugin version',
    buttonLabel: 'Run get plugin version',
    description: 'Return the installed native plugin version.',
    inputs: [],
    run: async () => plugin.getPluginVersion(),
  },
  {
    id: 'set-update-url',
    label: 'Set update URL',
    buttonLabel: 'Apply update URL',
    description: 'Point the example app at a custom update endpoint.',
    inputs: [
      {
        name: 'updateUrl',
        label: 'Update URL',
        type: 'text',
        value: 'https://example.com/api/auto_update',
        placeholder: 'https://example.com/api/auto_update',
      },
    ],
    run: async (values) => {
      if (!values.updateUrl) {
        throw new Error('Provide an update URL.');
      }
      await plugin.setUpdateUrl({ url: values.updateUrl });
      return 'Update URL set.';
    },
  },
];

const actionGrid = document.getElementById('smoke-actions');
const output = document.getElementById('plugin-output');
const actionStatus = document.getElementById('action-status');
const lastAction = document.getElementById('last-action');
const resultMarker = document.getElementById('result-marker');
const sequenceStatus = document.getElementById('sequence-status');
const runSmokeSequenceButton = document.getElementById('run-smoke-sequence');
const actionCards = new Map();

if (!actionGrid || !output || !actionStatus || !lastAction || !sequenceStatus || !runSmokeSequenceButton) {
  throw new Error('Smoke UI anchors are missing from index.html');
}

plugin.notifyAppReady().catch((error) => {
  console.error('notifyAppReady() bootstrap failed', error);
});

function formatResult(result) {
  if (result === undefined) {
    return 'Action completed.';
  }
  if (typeof result === 'string') {
    return result;
  }
  return JSON.stringify(result, null, 2);
}

function getCardValues(card, action) {
  const values = {};
  (action.inputs || []).forEach((input) => {
    const field = card.querySelector(`[name="${input.name}"]`);
    if (!field) {
      return;
    }
    values[input.name] = field.value;
  });
  return values;
}

async function runAction(action, values) {
  lastAction.textContent = `Last action: ${action.label}`;
  actionStatus.textContent = 'Status: running';
  resultMarker.textContent = `Result marker: ${action.id}:running`;
  output.textContent = `Running ${action.label}...`;

  try {
    const result = await action.run(values);
    actionStatus.textContent = 'Status: success';
    resultMarker.textContent = `Result marker: ${action.id}:success`;
    output.textContent = formatResult(result);
  } catch (error) {
    actionStatus.textContent = 'Status: error';
    resultMarker.textContent = `Result marker: ${action.id}:error`;
    output.textContent = `Error: ${error?.message ?? error}`;
    throw error;
  }
}

async function runSmokeSequence() {
  sequenceStatus.textContent = 'Sequence: running';
  runSmokeSequenceButton.disabled = true;

  try {
    for (const action of actions) {
      const card = actionCards.get(action.id);
      const values = card ? getCardValues(card, action) : {};
      await runAction(action, values);
    }
    sequenceStatus.textContent = 'Sequence: success';
    resultMarker.textContent = 'Result marker: smoke-sequence:success';
  } catch (error) {
    sequenceStatus.textContent = 'Sequence: error';
    resultMarker.textContent = 'Result marker: smoke-sequence:error';
  } finally {
    runSmokeSequenceButton.disabled = false;
  }
}

function createInputField(card, input) {
  const fieldWrapper = document.createElement('label');
  fieldWrapper.className = 'action-input';
  fieldWrapper.textContent = input.label;

  const field = document.createElement('input');
  field.type = input.type || 'text';
  field.name = input.name;
  field.value = input.value || '';
  if (input.placeholder) {
    field.placeholder = input.placeholder;
  }

  fieldWrapper.appendChild(field);
  card.appendChild(fieldWrapper);
}

function createActionCard(action) {
  const card = document.createElement('article');
  card.className = 'action-card';

  const title = document.createElement('h2');
  title.textContent = action.label;
  card.appendChild(title);

  const description = document.createElement('p');
  description.className = 'action-copy';
  description.textContent = action.description;
  card.appendChild(description);

  (action.inputs || []).forEach((input) => {
    createInputField(card, input);
  });

  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = action.buttonLabel;
  button.addEventListener('click', () => {
    const values = getCardValues(card, action);
    void runAction(action, values).catch(() => {});
  });
  card.appendChild(button);

  return card;
}

function renderActions() {
  actions.forEach((action) => {
    const card = createActionCard(action);
    actionCards.set(action.id, card);
    actionGrid.appendChild(card);
  });
}

runSmokeSequenceButton.addEventListener('click', () => {
  void runSmokeSequence();
});

renderActions();
