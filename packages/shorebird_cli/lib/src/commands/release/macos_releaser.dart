import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:shorebird_cli/src/archive_analysis/plist.dart';
import 'package:shorebird_cli/src/artifact_builder/artifact_builder.dart';
import 'package:shorebird_cli/src/artifact_manager.dart';
import 'package:shorebird_cli/src/code_push_client_wrapper.dart';
import 'package:shorebird_cli/src/commands/release/release.dart';
import 'package:shorebird_cli/src/doctor.dart';
import 'package:shorebird_cli/src/executables/xcodebuild.dart';
import 'package:shorebird_cli/src/extensions/arg_results.dart';
import 'package:shorebird_cli/src/logging/shorebird_logger.dart';
import 'package:shorebird_cli/src/metadata/update_release_metadata.dart';
import 'package:shorebird_cli/src/platform/platform.dart';
import 'package:shorebird_cli/src/release_type.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_validator.dart';
import 'package:shorebird_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// {@template macos_releaser}
/// Functions to build and publish a macOS release.
/// {@endtemplate}
class MacosReleaser extends Releaser {
  /// {@macro macos_releaser}
  MacosReleaser({
    required super.argResults,
    required super.flavor,
    required super.target,
  });

  /// If set, the value is the identity for productbuild signing. If null or empty, do not sign/pkg.
  String? get pkgSignIdentity => argResults['pkg-sign'] as String?;

  /// Whether to codesign the release.
  bool get codesign => argResults['codesign'] == true;

  @override
  ReleaseType get releaseType => ReleaseType.macos;

  @override
  String get artifactDisplayName => 'macOS app';

  @override
  Future<void> assertArgsAreValid() async {
    if (argResults.wasParsed('release-version')) {
      logger.err(
        '''
The "--release-version" flag is only supported for aar and ios-framework releases.
        
To change the version of this release, change your app's version in your pubspec.yaml.''',
      );
      throw ProcessExit(ExitCode.usage.code);
    }

    if (argResults.rest.contains('--obfuscate')) {
      // Obfuscated releases break patching, so we don't support them.
      // See https://github.com/shorebirdtech/shorebird/issues/1619
      logger
        ..err('Shorebird does not currently support obfuscation on macOS.')
        ..info(
          '''We hope to support obfuscation in the future. We are tracking this work at ${link(uri: Uri.parse('https://github.com/shorebirdtech/shorebird/issues/1619'))}.''',
        );
      throw ProcessExit(ExitCode.unavailable.code);
    }
  }

  @override
  Version? get minimumFlutterVersion => minimumSupportedMacosFlutterVersion;

  @override
  Future<void> assertPreconditions() async {
    try {
      await shorebirdValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
        checkShorebirdInitialized: true,
        validators: doctor.macosCommandValidators,
        supportedOperatingSystems: {Platform.macOS},
      );
    } on PreconditionFailedException catch (e) {
      throw ProcessExit(e.exitCode.code);
    }
  }

  @override
  Future<FileSystemEntity> buildReleaseArtifacts() async {
    if (!codesign) {
      logger
        ..info(
          '''Building for device with codesigning disabled. You will have to manually codesign before deploying to device.''',
        )
        ..warn(
          '''shorebird preview will not work for releases created with "--no-codesign". However, you can still preview your app by signing the generated .xcarchive in Xcode.''',
        );
    }

    await artifactBuilder.buildMacos(
      codesign: codesign,
      flavor: flavor,
      target: target,
      args: argResults.forwardedArgs,
      base64PublicKey: argResults.encodedPublicKey,
    );

    final appDirectory = artifactManager.getMacOSAppDirectory(flavor: flavor);
    if (appDirectory == null || !appDirectory.existsSync()) {
      logger.err('Unable to find .app directory at ${appDirectory?.path}');
      throw ProcessExit(ExitCode.software.code);
    }

    final identity = pkgSignIdentity;
    if (identity != null && identity.isNotEmpty) {
      final appName = p.basenameWithoutExtension(appDirectory.path);
      final pkgDir = Directory(
        p.join(projectRoot.path, 'build', 'macos', 'pkg'),
      );
      if (!pkgDir.existsSync()) {
        pkgDir.createSync(recursive: true);
      }
      final pkgPath = p.join(pkgDir.path, '$appName.pkg');
      final args = [
        '--component',
        appDirectory.path,
        '/Applications',
        '--sign',
        identity,
        pkgPath,
      ];
      logger.info('Running productbuild to create signed pkg...');
      final result = await Process.run('productbuild', args);
      if (result.exitCode != 0) {
        logger.err('productbuild failed: ${result.stderr}\n${result.stdout}');
        throw ProcessExit(result.exitCode);
      }
      logger.info('Created signed pkg at $pkgPath');
      return File(pkgPath);
    }

    return appDirectory;
  }

  @override
  Future<String> getReleaseVersion({
    required FileSystemEntity releaseArtifactRoot,
  }) async {
    final plistFile = File(
      p.join(releaseArtifactRoot.path, 'Contents', 'Info.plist'),
    );
    if (!plistFile.existsSync()) {
      logger.err('No Info.plist file found at ${plistFile.path}');
      throw ProcessExit(ExitCode.software.code);
    }

    try {
      return Plist(file: plistFile).versionNumber;
    } on Exception catch (error) {
      logger.err(
        '''Failed to determine release version from ${plistFile.path}: $error''',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }

  @override
  Future<void> uploadReleaseArtifacts({
    required Release release,
    required String appId,
  }) async {
    FileSystemEntity? uploadApp;
    final builtArtifact = artifactManager.getMacOSAppDirectory(flavor: flavor);
    final identity = pkgSignIdentity;
    File? pkgFile;
    if (identity != null && identity.isNotEmpty) {
      final appName = builtArtifact != null
          ? p.basenameWithoutExtension(builtArtifact.path)
          : null;
      final pkgPath = appName != null
          ? p.join(projectRoot.path, 'build', 'macos', 'pkg', '$appName.pkg')
          : null;
      if (pkgPath != null && File(pkgPath).existsSync()) {
        pkgFile = File(pkgPath);
      }
    }

    if (pkgFile != null) {
      final tempDir = Directory.systemTemp.createTempSync(
        'shorebird_pkg_extract_',
      );
      final expandResult = await Process.run('pkgutil', [
        '--expand',
        pkgFile.path,
        tempDir.path,
      ]);
      if (expandResult.exitCode != 0) {
        logger.err(
          'pkgutil --expand '
          'failed: ${expandResult.stderr}\n${expandResult.stdout}',
        );
        throw ProcessExit(expandResult.exitCode);
      }
      FileSystemEntity? foundApp;
      await for (final entity in tempDir.list(recursive: true)) {
        if (entity is Directory && entity.path.endsWith('.app')) {
          foundApp = entity;
          break;
        }
      }
      if (foundApp == null) {
        logger.err('No .app found in expanded .pkg');
        throw ProcessExit(ExitCode.software.code);
      }
      uploadApp = foundApp;
      logger.info('Uploading .app extracted from .pkg: ${foundApp.path}');
    } else {
      uploadApp = builtArtifact;
    }

    if (uploadApp == null || !uploadApp.existsSync()) {
      logger.err('Unable to find .app directory for upload');
      throw ProcessExit(ExitCode.software.code);
    }

    final String? podfileLockHash;
    if (shorebirdEnv.macosPodfileLockFile.existsSync()) {
      podfileLockHash = sha256
          .convert(shorebirdEnv.macosPodfileLockFile.readAsBytesSync())
          .toString();
    } else {
      podfileLockHash = null;
    }

    await codePushClientWrapper.createMacosReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      appPath: uploadApp.path,
      isCodesigned: codesign,
      podfileLockHash: podfileLockHash,
    );
  }

  @override
  Future<UpdateReleaseMetadata> updatedReleaseMetadata(
    UpdateReleaseMetadata metadata,
  ) async => metadata.copyWith(
    environment: metadata.environment.copyWith(
      xcodeVersion: await xcodeBuild.version(),
    ),
  );

  @override
  String get postReleaseInstructions =>
      '''

macOS app created at ${artifactManager.getMacOSAppDirectory(flavor: flavor)!.path}.
''';
}
