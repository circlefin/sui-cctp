/** @type {import('ts-jest/dist/types').JestConfigWithTsJest} */

module.exports = {
  preset: "ts-jest/presets/default-esm",
  extensionsToTreatAsEsm: [".ts"],
  testEnvironment: "node",
  testMatch: ["<rootDir>/test/**/*.test.[jt]s?(x)"],
  testPathIgnorePatterns: ["/dist", "/node_modules/"],

  maxWorkers: 1,
  testSequencer: "<rootDir>/testSequencer.cjs",
  coverageDirectory: "coverage",
  coveragePathIgnorePatterns: ["/node_modules/", "/test"],
  verbose: true,

  reporters: [
    "default",
    [
      "jest-junit",
      {
        outputDirectory: "report",
        uniqueOutputName: "true",
        outputName: "TEST-JEST.xml",
      },
    ],
  ],

  transform: {
    "^.+\\.ts?(x)$": ["ts-jest", { useESM: true, tsconfig: "tsconfig.json" }],
  },
};
