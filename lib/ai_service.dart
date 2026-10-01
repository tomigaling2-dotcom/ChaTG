import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class AiSource {
  final String title;
  final String url;
  final String? snippet;

  AiSource({
    required this.title,
    required this.url,
    this.snippet,
  });

  factory AiSource.fromJson(Map<String, dynamic> json) {
    return AiSource(
      title: json['title']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      snippet: json['snippet']?.toString(),
    );
  }
}

class AiChatResult {
  final String reply;
  final String? provider;
  final String? model;
  final List<AiSource> sources;

  AiChatResult({
    required this.reply,
    this.provider,
    this.model,
    this.sources = const [],
  });
}

class AiImageResult {
  final Uint8List bytes;
  final String mimeType;

  AiImageResult({
    required this.bytes,
    required this.mimeType,
  });
}

class AiService {
  static const String baseUrl = String.fromEnvironment(
    'CHATTG_BACKEND_URL',
    defaultValue: 'http://localhost:3000',
  );

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final response = await http
        .post(
          Uri.parse('$baseUrl$path'),
          headers: const {
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);

    Map<String, dynamic> data;

    try {
      final decoded = jsonDecode(response.body);

      data = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{};
    } catch (_) {
      data = <String, dynamic>{};
    }

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      final message =
          data['error']?.toString() ??
              'Backend request failed (HTTP ${response.statusCode}).';

      throw Exception(message);
    }

    return data;
  }

  Future<AiChatResult> chat({
    required String message,
    required List<Map<String, String>> history,
    bool useWebSearch = false,
    String? fileBase64,
    String? fileMimeType,
    String? fileName,
  }) async {
    final body = <String, dynamic>{
      'message': message,
      'history': history,
      'useWebSearch': useWebSearch,
      'provider': 'auto',
    };

    if (fileBase64 != null &&
        fileBase64.isNotEmpty) {
      body['fileBase64'] = fileBase64;
      body['fileMimeType'] =
          fileMimeType ??
              'application/octet-stream';
      body['fileName'] =
          fileName ?? 'attachment';
    }

    final data = await _post(
      '/chat',
      body,
    );

    final sources = <AiSource>[];

    final rawSources = data['sources'];

    if (rawSources is List) {
      for (final item in rawSources) {
        if (item is Map) {
          final source = AiSource.fromJson(
            Map<String, dynamic>.from(item),
          );

          if (source.url.isNotEmpty) {
            sources.add(source);
          }
        }
      }
    }

    return AiChatResult(
      reply:
          data['reply']?.toString() ??
              'The AI returned no text.',
      provider:
          data['provider']?.toString(),
      model:
          data['model']?.toString(),
      sources: sources,
    );
  }

  Future<AiImageResult> generateImage(
    String prompt,
    String userId,
  ) async {
    final data = await _post(
      '/image/generate',
      {
        'prompt': prompt,
        'userId': '',
      },
      timeout:
          const Duration(minutes: 5),
    );

    return _imageResultFromJson(data);
  }

  Future<AiImageResult> editImage({
    required Uint8List imageBytes,
    required String mimeType,
    required String prompt,
    required String userId,
  }) async {
    final data = await _post(
      '/image/edit',
      {
        'prompt': prompt,
        'imageBase64':
            base64Encode(imageBytes),
        'mimeType': mimeType,
        'userId': '',
      },
      timeout:
          const Duration(minutes: 5),
    );

    return _imageResultFromJson(data);
  }

  Future<String> analyzeImage({
    required Uint8List imageBytes,
    required String mimeType,
    String prompt =
        'Describe this image clearly and accurately.',
  }) async {
    final data = await _post(
      '/image/analyze',
      {
        'prompt': prompt,
        'imageBase64':
            base64Encode(imageBytes),
        'mimeType': mimeType,
        'userId': '',
      },
      timeout:
          const Duration(minutes: 3),
    );

    return data['reply']?.toString() ??
        'No image analysis was returned.';
  }

  AiImageResult _imageResultFromJson(
    Map<String, dynamic> data,
  ) {
    final value = data['base64'];

    if (value is! String ||
        value.isEmpty) {
      throw Exception(
        'The backend returned no image data.',
      );
    }

    try {
      return AiImageResult(
        bytes: base64Decode(value),
        mimeType:
            data['mimeType']?.toString() ??
                'image/png',
      );
    } catch (_) {
      throw Exception(
        'The backend returned invalid image data.',
      );
    }
  }
}