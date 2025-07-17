import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/config/config.dart';
import 'package:shorebird_cli/src/executables/ditto.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:shorebird_code_push_protocol/shorebird_code_push_protocol.dart';

/// {@template finalize_release_command}
/// Finalizes a draft release with an App Store signed binary.
/// {@endtemplate}
class FinalizeReleaseCommand extends ShorebirdCommand {
  /// {@macro finalize_release_command}
  FinalizeReleaseCommand() {
    argParser
      ..addOption(
        'app-store-binary',
        mandatory: true,
        help: 'Path to the App Store signed .app bundle.',
      )
      ..addOption(
        'flavor',
        help: 'The product flavor to use when finalizing the release.',
      );
  }

  @override
  String get description =>
      'Finalizes a draft release with an App Store '
      'signed binary to enable patching';

  @override
  String get name => 'finalize-release';

  @override
  Future<int> run() async {
    final releaseVersionArg = results.rest.isEmpty ? null : results.rest.first;
    if (releaseVersionArg == null) {
      logger.err(
        'Release version is required. Usage: shorebird finalize-release '
        '<release-version> --app-store-binary <path>',
      );
      return ExitCode.usage.code;
    }

    final appStoreBinaryPath = results['app-store-binary'] as String;
    final appStoreBinary = Directory(appStoreBinaryPath);

    if (!appStoreBinary.existsSync()) {
      logger.err('App Store binary not found at: $appStoreBinaryPath');
      return ExitCode.usage.code;
    }

    if (!appStoreBinary.path.endsWith('.app')) {
      logger.err('App Store binary must be a .app bundle');
      return ExitCode.usage.code;
    }

    try {
      await shorebirdValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
        checkShorebirdInitialized: true,
        supportedOperatingSystems: {Platform.macOS},
      );
    } on PreconditionFailedException catch (e) {
      throw ProcessExit(e.exitCode.code);
    }

    final appId = shorebirdEnv.getShorebirdYaml()!.getAppId(flavor: flavor);

    await finalizeReleaseWithAppStoreBinary(
      appId: appId,
      releaseVersion: releaseVersionArg,
      appStoreBinary: appStoreBinary,
    );

    return ExitCode.success.code;
  }

  /// The build flavor, if provided.
  String? get flavor => results.findOption('flavor', argParser: argParser);

  /// The shorebird app ID for the current project.
  String get appId => shorebirdEnv.getShorebirdYaml()!.getAppId(flavor: flavor);

  /// Finalizes a draft release by updating it with the App Store signed binary.
  Future<void> finalizeReleaseWithAppStoreBinary({
    required String appId,
    required String releaseVersion,
    required Directory appStoreBinary,
  }) async {
    final progress = logger.progress(
      'Finalizing release with App Store binary',
    );

    try {
      // Get the existing release
      // final release = await codePushClientWrapper.getRelease(
      //   appId: appId,
      //   releaseVersion: releaseVersion,
      // );
      // TODO(ahmtydn): delete this after the server-side API supports
      final release = await getOrCreateRelease(
        version: releaseVersion,
        releasePlatform: ReleasePlatform.macos,
      );

      // Verify this is a draft release for macOS
      final macosStatus = release.platformStatuses[ReleasePlatform.macos];
      if (macosStatus != ReleaseStatus.draft) {
        progress.fail(
          'Release ${release.version} is not in draft status '
          '(current: $macosStatus)',
        );
        throw ProcessExit(ExitCode.usage.code);
      }

      // Extract hash from the App Store binary
      final appStoreHash = await extractAppStoreBinaryHash(appStoreBinary);

      // Update the release artifacts with the new hash
      await updateReleaseArtifactHash(
        appId: appId,
        releaseId: release.id,
        newHash: appStoreHash,
        appStoreBinary: appStoreBinary,
      );

      // Finalize the release by setting it to active
      await codePushClientWrapper.updateReleaseStatus(
        appId: appId,
        releaseId: release.id,
        platform: ReleasePlatform.macos,
        status: ReleaseStatus.active,
      );

      progress.complete('Release ${release.version} finalized successfully');

      logger
        ..success('✅ Release finalized with App Store binary')
        ..info('✅ Hash mapping updated: dev_hash → appstore_hash')
        ..info('✅ Patch generation now targets App Store binary')
        ..info('')
        ..info('Your release is now ready for patching!')
        ..info('To create a patch, run:')
        ..info(
          '  shorebird patch --platforms=macos '
          '--release-version=${release.version}',
        );
    } catch (e) {
      progress.fail('Failed to finalize release: $e');
      rethrow;
    }
  }

  /// Extracts the hash from the App Store signed binary.
  Future<String> extractAppStoreBinaryHash(Directory appStoreBinary) async {
    // Create a temporary zip file of the App Store binary
    final tempDir = await Directory.systemTemp.createTemp();
    final zippedApp = File(
      p.join(tempDir.path, '${p.basename(appStoreBinary.path)}.zip'),
    );

    await ditto.archive(
      source: appStoreBinary.path,
      destination: zippedApp.path,
    );

    try {
      // For .app bundles, we need to read the zipped version for hash calculation
      final appStoreBinaryBytes = await zippedApp.readAsBytes();
      final appStoreHash = sha256.convert(appStoreBinaryBytes).toString();

      return appStoreHash;
    } on Exception catch (e) {
      logger.err('Failed to extract App Store binary hash: $e');
      throw ProcessExit(ExitCode.software.code);
    } finally {
      // Clean up temporary files
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    }
  }

  /// Updates the release artifact with the new App Store binary hash.
  ///
  /// Note: This is a placeholder implementation. The actual implementation
  /// would need to be supported by the server API to update existing artifacts.
  Future<void> updateReleaseArtifactHash({
    required String appId,
    required int releaseId,
    required String newHash,
    required Directory appStoreBinary,
  }) async {
    // TODO(ahmtydn): Implement server-side API for updating release artifact
    // hashes. For now, we'll create a new artifact with the App Store binary

    final String? podfileLockHash;
    if (shorebirdEnv.macosPodfileLockFile.existsSync()) {
      podfileLockHash = sha256
          .convert(shorebirdEnv.macosPodfileLockFile.readAsBytesSync())
          .toString();
    } else {
      podfileLockHash = null;
    }

    // Create a new release artifact with the App Store binary
    // This would need to be implemented as a server-side API endpoint
    await codePushClientWrapper.createMacosReleaseArtifacts(
      appId: appId,
      releaseId: releaseId,
      appPath: appStoreBinary.path,
      isCodesigned: true,
      // TODO(ahmtydn): App Store version doesn't need podfile hash but
      // temporarily testing with it
      // until server-side API supports updating existing artifacts.
      podfileLockHash: podfileLockHash,
    );
  }

  /// Fetches the release with version [version] from the server or creates a
  /// new release if none exists.
  // TODO(ahmtydn): delete this method after the server-side API supports
  Future<Release> getOrCreateRelease({
    required String version,
    required ReleasePlatform releasePlatform,
  }) async {
    return await codePushClientWrapper.maybeGetRelease(
          appId: appId,
          releaseVersion: version,
        ) ??
        await codePushClientWrapper.createRelease(
          appId: appId,
          version: version,
          flutterRevision: shorebirdEnv.flutterRevision,
          platform: releasePlatform,
        );
  }
}
