// Lifts every injected fault on the fake Capgo server (the network "comes back").
// Maestro runs this on the host, so HOST_SERVER_URL is the host loopback URL.
for (const target of ['bundle', 'update']) {
  const response = http.post(
    `${HOST_SERVER_URL}/api/control/fault?scenario=${SCENARIO_ID}&target=${target}&mode=none`,
    {
      body: '',
    },
  );

  if (!response.ok) {
    throw new Error(`Clearing the ${target} fault failed with HTTP ${response.status}`);
  }
}
