import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A FIFO queue of canned responses plus a record of every request made — the
/// shared test seam the SDK's injectable `http.Client` exists for. Mirrors the
/// helper in `atlas_client_test.dart`, lifted out so the flow / me / widget
/// suites reuse it.
class MockTransport {
  final List<http.BaseRequest> recorded = [];
  final List<_Stub> _stubs = [];

  /// `GET /v1/appearance` is answered from here, OUTSIDE the FIFO queue and the
  /// [recorded] list, so a widget's background appearance fetch never shifts
  /// the canned flow responses. Defaults to "no design saved".
  String appearanceJson = '{"object":"appearance","design":null,"providers":[]}';
  int appearanceStatus = 200;
  final List<http.BaseRequest> appearanceRequests = [];

  void enqueue(int status, String json,
      {Map<String, String> headers = const {}}) {
    final merged = <String, String>{'content-type': 'application/json', ...headers};
    _stubs.add(_Stub(status, json, merged));
  }

  http.Client client() => MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/v1/appearance') {
          appearanceRequests.add(request);
          return http.Response(appearanceJson, appearanceStatus,
              headers: {'content-type': 'application/json'}, request: request);
        }
        recorded.add(request);
        if (_stubs.isEmpty) {
          throw http.ClientException('no stubbed response', request.url);
        }
        final stub = _stubs.removeAt(0);
        return http.Response(
          stub.body,
          stub.status,
          headers: stub.headers,
          request: request,
        );
      });

  http.Request reqAt(int index) => recorded[index] as http.Request;

  Map<String, dynamic> bodyAt(int index) =>
      jsonDecode(reqAt(index).body) as Map<String, dynamic>;

  String pathAt(int index) => recorded[index].url.path;

  String methodAt(int index) => recorded[index].method;
}

class _Stub {
  _Stub(this.status, this.body, this.headers);
  final int status;
  final String body;
  final Map<String, String> headers;
}

const pk = 'pk_test_123';
const frontendApi = 'clerk.example.com';
