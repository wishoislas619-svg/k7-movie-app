import 'package:flutter/material.dart';
import '../../../../features/movies/presentation/pages/admin_movie_page.dart';
import '../../../../features/auth/presentation/pages/admin_users_page.dart';
import '../../../../features/movies/presentation/pages/admin_categories_page.dart';
import '../../../../features/movies/presentation/pages/admin_popular_movies_page.dart';
import '../../../../features/series/presentation/pages/admin_series_page.dart';
import '../../../../features/series/presentation/pages/admin_series_categories_page.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  int _selectedIndex = 0;

  final List<Widget> _pages = [
    const AdminMoviePage(),
    const AdminCategoriesPage(),
    const AdminSeriesPage(),
    const AdminSeriesCategoriesPage(),
    const AdminUsersPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _pages[_selectedIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.9),
          border: const Border(top: BorderSide(color: Colors.white10, width: 0.5)),
        ),
        child: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: (index) => setState(() => _selectedIndex = index),
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: const Color(0xFF00A3FF),
          unselectedItemColor: Colors.white38,
          selectedFontSize: 9,
          unselectedFontSize: 9,
          type: BottomNavigationBarType.fixed,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.movie_creation_outlined),
              activeIcon: Icon(Icons.movie_creation),
              label: 'PELÍCULAS',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.category_outlined),
              activeIcon: Icon(Icons.category),
              label: 'CAT. PELIS',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.live_tv_outlined),
              activeIcon: Icon(Icons.live_tv),
              label: 'SERIES',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.format_list_bulleted),
              activeIcon: Icon(Icons.format_list_bulleted),
              label: 'CAT. SERIES',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.people_outline),
              activeIcon: Icon(Icons.people),
              label: 'USUARIOS',
            ),
          ],
        ),
      ),
    );
  }
}
