/** @type {import('jest').Config} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  rootDir: '.',
  testMatch: ['<rootDir>/test/**/*.spec.ts'],
  // Scenarios run one file at a time, in filename order (numeric prefixes)
  // because 03-crash-mid-saga pauses/kills the shared containers — running
  // files concurrently would corrupt other scenarios' in-flight sagas.
  // (npm test / package.json passes --runInBand for the same reason.)
  testSequencer: '<rootDir>/test/support/sequencer.js',
  testTimeout: 120000,
  maxWorkers: 1,
  verbose: true,
};
