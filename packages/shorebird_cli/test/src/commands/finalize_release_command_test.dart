import 'package:args/args.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/finalize_release_command.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group(FinalizeReleaseCommand, () {
    late ArgResults argResults;
    late CodePushClientWrapper codePushClientWrapper;
    late ShorebirdEnv shorebirdEnv;
    late ShorebirdValidator shorebirdValidator;
    late ShorebirdLogger logger;
    late FinalizeReleaseCommand command;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
          loggerRef.overrideWith(() => logger),
          shorebirdEnvRef.overrideWith(() => shorebirdEnv),
          shorebirdValidatorRef.overrideWith(() => shorebirdValidator),
        },
      );
    }

    setUp(() {
      argResults = MockArgResults();
      codePushClientWrapper = MockCodePushClientWrapper();
      shorebirdEnv = MockShorebirdEnv();
      shorebirdValidator = MockShorebirdValidator();
      logger = MockShorebirdLogger();

      command = runWithOverrides(FinalizeReleaseCommand.new)
        ..testArgResults = argResults;
    });

    group('name', () {
      test('returns "finalize-release"', () {
        expect(command.name, equals('finalize-release'));
      });
    });

    group('description', () {
      test('returns correct description', () {
        expect(
          command.description,
          equals(
            'Finalizes a draft release with an App Store signed binary to '
            'enable patching',
          ),
        );
      });
    });

    group('run', () {
      test('returns usage error when no release version provided', () async {
        when(() => argResults.rest).thenReturn(<String>[]);

        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.usage.code));
        verify(
          () => logger.err(
            'Release version is required. Usage: shorebird finalize-release '
            '<release-version> --app-store-binary <path>',
          ),
        ).called(1);
      });

      test('returns error when App Store binary file does not exist', () async {
        const releaseVersion = '1.0.0';
        const appStoreBinaryPath = '/path/to/nonexistent.app';

        when(() => argResults.rest).thenReturn([releaseVersion]);
        when(
          () => argResults['app-store-binary'],
        ).thenReturn(appStoreBinaryPath);

        final result = await runWithOverrides(command.run);

        expect(result, equals(ExitCode.usage.code));
        verify(
          () =>
              logger.err('App Store binary not found at: $appStoreBinaryPath'),
        ).called(1);
      });
    });
  });
}
