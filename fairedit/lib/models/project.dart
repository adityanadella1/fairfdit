import 'package:path/path.dart' as p;

class EditProject {
  final String id;
  final String name;
  final String imagePath;
  final DateTime createdAt;

  const EditProject({
    required this.id,
    required this.name,
    required this.imagePath,
    required this.createdAt,
  });

  /// Where EditProvider saves a rendered preview of the current edits.
  /// Lives next to the original inside the project's own folder. Home
  /// screen falls back to [imagePath] if this file doesn't exist yet
  /// (e.g. a project that's never been opened for editing).
  String get previewPath => p.join(p.dirname(imagePath), 'preview.png');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'imagePath': imagePath,
        'createdAt': createdAt.toIso8601String(),
      };

  factory EditProject.fromJson(Map<String, dynamic> json) => EditProject(
        id: json['id'] as String,
        name: json['name'] as String,
        imagePath: json['imagePath'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}
