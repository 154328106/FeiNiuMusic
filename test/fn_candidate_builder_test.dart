import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/feiniu/fn_models.dart';

FnConnectionParams _params() {
  return FnConnectionParams(
    internalIPv4s: ['192.168.1.10'],
    publicIPv4s: ['1.2.3.4'],
    publicIPv6s: ['2409::1'],
    httpsPort: 5667,
    httpPort: 5666,
    relayAddresses: ['myid.5ddd.com:443'],
  );
}

void main() {
  test('default order builds internal → v6 → v4 → relay', () {
    final specs = buildProbeCandidateSpecs(
      fnId: 'myid',
      params: _params(),
      order: kDefaultConnectionOrder,
      preferHttps: true,
    );

    final addresses = specs.map((s) => s.address).toList();
    expect(addresses, [
      // 内网 HTTPS → HTTP
      'https://192.168.1.10:5667',
      'http://192.168.1.10:5666',
      // 公网 IPv6 HTTPS → HTTP
      'https://[2409::1]:5667',
      'http://[2409::1]:5666',
      // 公网 IPv4 HTTPS → HTTP
      'https://1.2.3.4:5667',
      'http://1.2.3.4:5666',
      // 中继（仅 HTTPS）
      'https://myid.5ddd.com',
    ]);
    expect(specs.last.group, ProbeCandidateGroup.relay);
    expect(specs.last.relayMode, true);
  });

  test('preferHttps false puts HTTP before HTTPS within each group', () {
    final specs = buildProbeCandidateSpecs(
      fnId: 'myid',
      params: _params(),
      order: kDefaultConnectionOrder,
      preferHttps: false,
    );

    final addresses = specs.map((s) => s.address).toList();
    expect(addresses, [
      // 内网 HTTP → HTTPS
      'http://192.168.1.10:5666',
      'https://192.168.1.10:5667',
      // 公网 IPv6 HTTP → HTTPS
      'http://[2409::1]:5666',
      'https://[2409::1]:5667',
      // 公网 IPv4 HTTP → HTTPS
      'http://1.2.3.4:5666',
      'https://1.2.3.4:5667',
      // 中继（始终 HTTPS）
      'https://myid.5ddd.com',
    ]);
  });

  test('custom order controls group sequence', () {
    final specs = buildProbeCandidateSpecs(
      fnId: 'myid',
      params: _params(),
      order: [ProbeCandidateGroup.relay, ProbeCandidateGroup.internal],
      preferHttps: true,
    );

    final groups = specs.map((s) => s.group).toList();
    expect(groups, [
      ProbeCandidateGroup.relay,
      ProbeCandidateGroup.internal,
      ProbeCandidateGroup.internal,
    ]);
  });

  test('empty relay addresses falls back to fnId.5ddd.com', () {
    final params = FnConnectionParams(
      internalIPv4s: const [],
      publicIPv4s: const [],
      publicIPv6s: const [],
      httpsPort: 5667,
      httpPort: 5666,
      relayAddresses: const [],
    );

    final specs = buildProbeCandidateSpecs(
      fnId: 'myid',
      params: params,
      order: kDefaultConnectionOrder,
      preferHttps: true,
    );

    expect(specs.length, 1);
    expect(specs.single.address, 'https://myid.5ddd.com');
  });
}
