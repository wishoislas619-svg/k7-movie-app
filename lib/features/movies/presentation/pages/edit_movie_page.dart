import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../providers.dart';
import '../../domain/entities/movie.dart';
import '../providers/movie_provider.dart';
import '../providers/category_provider.dart';

class EditMoviePage extends ConsumerStatefulWidget {
  final Movie? movie;
  const EditMoviePage({super.key, this.movie});

  @override
  ConsumerState<EditMoviePage> createState() => _EditMoviePageState();
}

class _EditMoviePageState extends ConsumerState<EditMoviePage> {
  late TextEditingController _nameController;
  late TextEditingController _imageController;
  String? _selectedCategoryId;
  List<VideoOption> _options = [];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.movie?.name ?? '');
    _imageController = TextEditingController(text: widget.movie?.imagePath ?? '');
    _selectedCategoryId = widget.movie?.categoryId;
    if (widget.movie != null) {
      _loadOptions();
    }
  }

  void _loadOptions() async {
    final opts = await ref.read(movieRepositoryProvider).getVideoOptions(widget.movie!.id);
    setState(() => _options = opts);
  }

  void _saveMovie() async {
    if (widget.movie == null) {
      await ref.read(moviesProvider.notifier).addMovie(
        _nameController.text, 
        _imageController.text,
        categoryId: _selectedCategoryId,
      );
    } else {
      final updatedMovie = Movie(
        id: widget.movie!.id,
        name: _nameController.text,
        imagePath: _imageController.text,
        categoryId: _selectedCategoryId,
        createdAt: widget.movie!.createdAt,
      );
      await ref.read(moviesProvider.notifier).updateMovie(updatedMovie);
    }
    if (mounted) Navigator.pop(context);
  }

  void _deleteMovie() async {
    if (widget.movie != null) {
      await ref.read(moviesProvider.notifier).deleteMovie(widget.movie!.id);
      if (mounted) Navigator.pop(context);
    }
  }

  void _showOptionModal([VideoOption? option]) {
    final resController = TextEditingController(text: option?.resolution ?? '');
    final urlController = TextEditingController(text: option?.videoUrl ?? '');
    final imgController = TextEditingController(text: option?.serverImagePath ?? '');

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(option == null ? 'Agregar Opción' : 'Editar Opción'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: imgController, decoration: const InputDecoration(labelText: 'URL Imagen Servidor')),
            TextField(controller: resController, decoration: const InputDecoration(labelText: 'Resolución (ej: 1080P)')),
            TextField(controller: urlController, decoration: const InputDecoration(labelText: 'URL Video')),
          ],
        ),
        actions: [
          if (option != null)
            TextButton(
              onPressed: () async {
                await ref.read(movieRepositoryProvider).deleteVideoOption(option.id);
                _loadOptions();
                if (mounted) Navigator.pop(context);
              },
              child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
            ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          TextButton(
            onPressed: () async {
              final newOpt = VideoOption(
                id: option?.id ?? '',
                movieId: widget.movie!.id,
                serverImagePath: imgController.text,
                resolution: resController.text,
                videoUrl: urlController.text,
              );
              if (option == null) {
                await ref.read(movieRepositoryProvider).addVideoOption(newOpt);
              } else {
                await ref.read(movieRepositoryProvider).updateVideoOption(newOpt);
              }
              _loadOptions();
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(categoriesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(widget.movie == null ? 'Nueva Película' : 'Editar Película')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(controller: _imageController, decoration: const InputDecoration(labelText: 'URL Imagen Película')),
            const SizedBox(height: 16),
            categoriesAsync.when(
              data: (categories) {
                // Ensure the selected ID exists in the current categories list to avoid assertion errors
                final bool exists = _selectedCategoryId == null || categories.any((c) => c.id == _selectedCategoryId);
                final dropdownValue = exists ? _selectedCategoryId : null;

                return DropdownButtonFormField<String>(
                  value: dropdownValue,
                  decoration: const InputDecoration(labelText: 'Categoría'),
                  items: [
                    const DropdownMenuItem<String>(value: null, child: Text('Sin Categoría')),
                    ...categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))),
                  ],
                  onChanged: (val) => setState(() => _selectedCategoryId = val),
                );
              },
              loading: () => const CircularProgressIndicator(),
              error: (e, s) => Text('Error cargando categorías: $e'),
            ),
            const SizedBox(height: 16),
            TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Nombre de la Película')),
            const SizedBox(height: 32),
            const Text('Opciones de Video', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (widget.movie == null)
              const Text('Guarda la película primero para agregar opciones.')
            else ...[
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _options.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    leading: Text('Opción ${index + 1}'),
                    title: Text(_options[index].resolution),
                    onTap: () => _showOptionModal(_options[index]),
                  );
                },
              ),
              ElevatedButton.icon(
                onPressed: () => _showOptionModal(),
                icon: const Icon(Icons.add),
                label: const Text('Agregar nueva opción'),
              ),
            ],
            const SizedBox(height: 48),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (widget.movie != null)
                  ElevatedButton(
                    onPressed: _deleteMovie,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                    child: const Text('Eliminar Película'),
                  ),
                ElevatedButton(
                  onPressed: _saveMovie,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                  child: const Text('Guardar Cambios'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
