import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../providers/category_provider.dart';
import '../../domain/entities/category.dart';

class AdminCategoriesPage extends ConsumerWidget {
  const AdminCategoriesPage({super.key});

  void _showCategoryDialog(BuildContext context, WidgetRef ref, [Category? category]) {
    final controller = TextEditingController(text: category?.name ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.white.withOpacity(0.1))),
        title: Text(category == null ? 'NUEVA CATEGORÍA' : 'EDITAR CATEGORÍA', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Nombre de la Categoría',
            labelStyle: const TextStyle(color: Color(0xFF00A3FF), fontSize: 13, fontWeight: FontWeight.bold),
            filled: true,
            fillColor: Colors.white.withOpacity(0.04),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00A3FF))),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCELAR', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                if (category == null) {
                  await ref.read(categoriesProvider.notifier).addCategory(controller.text);
                } else {
                  await ref.read(categoriesProvider.notifier).updateCategory(
                    Category(id: category.id, name: controller.text)
                  );
                }
                if (context.mounted) Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00A3FF),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('GUARDAR', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categoriesAsync = ref.watch(categoriesProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: const Text(
          'CATEGORÍAS',
          style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 16),
        ),
      ),
      body: categoriesAsync.when(
        data: (categories) => ListView.builder(
          padding: const EdgeInsets.only(bottom: 120),
          itemCount: categories.length,
          itemBuilder: (context, index) {
            final category = categories[index];
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: ListTile(
                title: Text(category.name, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), shape: BoxShape.circle),
                      child: IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blueAccent, size: 20),
                        onPressed: () => _showCategoryDialog(context, ref, category),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), shape: BoxShape.circle),
                      child: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: const Color(0xFF1E1E1E),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.white.withOpacity(0.1))),
                              title: const Text('ELIMINAR CATEGORÍA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              content: const Text('¿Estás seguro? Las películas de esta categoría se quedarán sin categoría, pero NO se borrarán.', style: TextStyle(color: Colors.white70)),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCELAR', style: TextStyle(color: Colors.white54))),
                                ElevatedButton(
                                  onPressed: () {
                                    ref.read(categoriesProvider.notifier).deleteCategory(category.id);
                                    Navigator.pop(context);
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.redAccent,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  child: const Text('ELIMINAR', style: TextStyle(fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('Error: $e')),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00A3FF).withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: FloatingActionButton(
          onPressed: () => _showCategoryDialog(context, ref),
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
          child: const Icon(Icons.add),
        ),
        ),
      ),
    );
  }
}
