import 'package:ccs_mobile_studio/core/services/app_update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('version comparison includes build numbers', () {
    expect(AppUpdateService.compareVersions('1.0.5+7', '1.0.5+6'), 1);
    expect(AppUpdateService.compareVersions('v1.1.0', '1.0.9+99'), 1);
    expect(AppUpdateService.compareVersions('1.0.5+6', '1.0.5+6'), 0);
  });

  test('release assets are selected for each supported platform', () {
    final assets = <Map<String, Object>>[
      {
        'name': 'CCS-Mobile-Studio-1.1.0-Android.apk',
        'browser_download_url': 'https://example.test/app.apk',
        'size': 100,
      },
      {
        'name': 'CCS-Mobile-Studio-1.1.0-macOS-universal.zip',
        'browser_download_url': 'https://example.test/app-mac.zip',
        'size': 200,
      },
      {
        'name': 'CCS-Mobile-Studio-1.1.0-Windows-x64.zip',
        'browser_download_url': 'https://example.test/app-win.zip',
        'size': 300,
      },
    ];

    expect(
      AppUpdateService.findAsset(
        assets,
        platform: UpdatePlatform.android,
      )?.name,
      contains('Android'),
    );
    expect(
      AppUpdateService.findAsset(assets, platform: UpdatePlatform.macos)?.name,
      contains('macOS'),
    );
    expect(
      AppUpdateService.findAsset(
        assets,
        platform: UpdatePlatform.windows,
      )?.name,
      contains('Windows'),
    );
  });
}
