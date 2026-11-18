/// Base URL of the upstream server: the tracker OAuth proxy (`/auth`), log
/// uploads (`/logs`) and Discord posters (`/posters`). Watch Together rooms
/// run on Open Watch Party relays, not here.
// VyseTV: never call upstream's own services (their trademark rules); trackers live elsewhere in VyseTV.
const String appServerBaseUrl = 'https://invalid.invalid';
