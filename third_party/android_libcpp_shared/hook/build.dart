import 'dart:io';

import 'package:android_libcpp_shared/src/locate_ndk.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';

Uri? _libcppFromCompiler(BuildInput input, Logger logger) {
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null || !compiler.isScheme('file')) {
    return null;
  }

  final compilerFile = compiler.toFilePath();
  const toolchainMarker = '/toolchains/llvm/prebuilt/';
  final markerIndex = compilerFile.indexOf(toolchainMarker);
  if (markerIndex == -1) {
    return null;
  }

  final binIndex = compilerFile.lastIndexOf('/bin/');
  if (binIndex == -1 || binIndex <= markerIndex) {
    return null;
  }

  final targetArch =
      LibArch.fromString(input.config.code.targetArchitecture.name) ??
      LibArch.fromString(input.config.code.targetArchitecture.toString());
  if (targetArch == null) {
    return null;
  }

  final prebuiltPath = compilerFile.substring(0, binIndex);
  final triple = targetArch.toTriple();
  final api = input.config.code.android.targetNdkApi;
  final apiSpecific = Uri.file(
    '$prebuiltPath/sysroot/usr/lib/$triple/$api/libc++_shared.so',
  );
  if (File.fromUri(apiSpecific).existsSync()) {
    logger.info('Using libc++_shared.so from compiler sysroot: $apiSpecific');
    return apiSpecific;
  }

  final generic = Uri.file(
    '$prebuiltPath/sysroot/usr/lib/$triple/libc++_shared.so',
  );
  if (File.fromUri(generic).existsSync()) {
    logger.info(
      'Using generic libc++_shared.so from compiler sysroot: $generic',
    );
    return generic;
  }

  return null;
}

void main(List<String> args) async {
  final logger = Logger('AndroidLibcppSharedHook')
    ..onRecord.listen((record) {
      print('${record.level.name}: ${record.message}');
    });

  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    final targetOs = input.config.code.targetOS;
    if (targetOs != OS.android) {
      logger.info(
        'Target OS is $targetOs, skipping Android system library inclusion.',
      );
      return;
    }

    final Architecture targetArchitecture =
        input.config.code.targetArchitecture;

    logger.info('Searching for android NDK...');
    final ndkPaths = await NDKLocator.locate();
    final ndk = ndkPaths.forBuildConfig(input.config);
    final libcppSharedPath = ndk == null
        ? _libcppFromCompiler(input, logger)
        : ndk.hostArchitectures.first.targetArchitectures.first.sysrootLibPath
              .resolve('libc++_shared.so');
    if (libcppSharedPath == null) {
      throw StateError(
        'No suitable NDK found for target architecture $targetArchitecture.',
      );
    }
    if (ndk != null) {
      logger.info('Found NDK at ${ndk.path}, version ${ndk.version}.');
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'libc++_shared.so',
        file: libcppSharedPath,
        linkMode: DynamicLoadingBundled(),
      ),
    );
  });
}
