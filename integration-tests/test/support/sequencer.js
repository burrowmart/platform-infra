const Sequencer = require('@jest/test-sequencer').default;

/** Plain alphabetical order — Jest's default sequencer reorders by file size,
 * which would break the numeric-prefix ordering these scenario files rely on
 * (03-crash-mid-saga must run after 01/02 and before 04, see jest.config.js). */
class AlphabeticalSequencer extends Sequencer {
  sort(tests) {
    return [...tests].sort((a, b) => a.path.localeCompare(b.path));
  }
}

module.exports = AlphabeticalSequencer;
