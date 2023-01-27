/*-
 * Copyright (c) 2014-2020 elementary, Inc. (https://elementary.io)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Authored by: Corentin Noël <corentin@elementary.io>
 *              Jeremy Wootten <jeremy@elementaryos.org>
 */

namespace AppCenter.Views {
/** AppList for the Updates View. Sorts update_available first and shows headers.
      * Does not show Uninstall Button **/
    public class AppListUpdateView : Gtk.Box {
        public signal void show_app (AppCenterCore.Package package);

        private Granite.Widgets.AlertView loading_view;
        private Granite.Widgets.AlertView updated_placeholder;
        private Granite.Widgets.AlertView restart_placeholder;
        private Granite.HeaderLabel header_label;
        private Gtk.Button update_all_button;
        private Gtk.FlowBox installed_flowbox;
        private Gtk.ListBox list_box;
        private Gtk.Revealer header_revealer;
        private Gtk.SizeGroup action_button_group;
        private Gtk.Stack placeholder_stack;
        private Widgets.SizeLabel size_label;
        private bool updating_all_apps = false;
        private Cancellable? refresh_cancellable = null;
        private AsyncMutex refresh_mutex = new AsyncMutex ();

        construct {
            var css_provider = new Gtk.CssProvider ();
            css_provider.load_from_resource ("io/elementary/appcenter/AppListUpdateView.css");

            loading_view = new Granite.Widgets.AlertView (
                _("Checking for Updates"),
                _("Downloading a list of available updates to the OS and installed apps"),
                "sync-synchronizing"
            );
            loading_view.show_all ();

            restart_placeholder = new Granite.Widgets.AlertView (
                _("Updates Are Ready to Install"),
                _("A restart is required to finish installing updates"),
                "software-update-available"
            );
            restart_placeholder.show_action (_("Restart Now"));
            restart_placeholder.show_all ();

            updated_placeholder = new Granite.Widgets.AlertView (
                _("Everything Is Up to Date"),
                "",
                "process-completed"
            );
            updated_placeholder.show_all ();

            placeholder_stack = new Gtk.Stack ();
            placeholder_stack.add (loading_view);
            placeholder_stack.add (restart_placeholder);
            placeholder_stack.add (updated_placeholder);
            placeholder_stack.show_all ();

            header_label = new Granite.HeaderLabel ("") {
                hexpand = true
            };

            size_label = new Widgets.SizeLabel () {
                halign = Gtk.Align.END,
                valign = Gtk.Align.CENTER
            };

            update_all_button = new Gtk.Button.with_label (_("Update All")) {
                valign = Gtk.Align.CENTER
            };
            update_all_button.get_style_context ().add_class (Gtk.STYLE_CLASS_SUGGESTED_ACTION);

            var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 16);
            header.add (header_label);
            header.add (size_label);
            header.add (update_all_button);
            header.get_style_context ().add_provider (css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

            header_revealer = new Gtk.Revealer ();
            header_revealer.add (header);
            header_revealer.get_style_context ().add_class ("header");
            header_revealer.get_style_context ().add_provider (css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

            list_box = new Gtk.ListBox () {
                activate_on_single_click = true,
                hexpand = true,
                vexpand = true
            };
            list_box.set_sort_func ((Gtk.ListBoxSortFunc) package_row_compare);
            list_box.set_header_func ((Gtk.ListBoxUpdateHeaderFunc) row_update_header);
            list_box.set_placeholder (placeholder_stack);

            var installed_header = new Granite.HeaderLabel (_("Up to Date")) {
                margin_top = 24,
                margin_end = 12,
                margin_bottom = 12,
                margin_start = 12,
            };

            installed_flowbox = new Gtk.FlowBox () {
                column_spacing = 24,
                homogeneous = true,
                max_children_per_line = 4,
                row_spacing = 12
            };
            installed_flowbox.set_sort_func ((Gtk.FlowBoxSortFunc) installed_sort_func);

            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            box.add (list_box);
            box.add (installed_header);
            box.add (installed_flowbox);
            box.get_style_context ().add_class (Gtk.STYLE_CLASS_VIEW);

            var scrolled = new Gtk.ScrolledWindow (null, null) {
                hscrollbar_policy = Gtk.PolicyType.NEVER
            };
            scrolled.add (box);
            scrolled.get_style_context ().add_provider (css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

            action_button_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.BOTH);
            action_button_group.add_widget (update_all_button);

            restart_placeholder.action_activated.connect (() => {
                try {
                    SuspendControl.get_default ().reboot ();
                } catch (GLib.Error e) {
                    if (!(e is IOError.CANCELLED)) {
                        restart_placeholder.description = _("Requesting a restart failed. Restart manually to finish installing updates");
                        restart_placeholder.hide_action ();
                    }
                }
            });

            unowned var update_manager = AppCenterCore.UpdateManager.get_default ();
            update_manager.notify["restart-required"].connect (() => {
                if (update_manager.restart_required) {
                    placeholder_stack.visible_child = restart_placeholder;
                }
            });

            orientation = Gtk.Orientation.VERTICAL;
            add (header_revealer);
            add (scrolled);

            get_apps.begin ();

            unowned var client = AppCenterCore.Client.get_default ();
            client.installed_apps_changed.connect (() => {
                Idle.add (() => {
                    get_apps.begin ();
                    return GLib.Source.REMOVE;
                });
            });

            list_box.row_activated.connect ((row) => {
                if (row is Widgets.PackageRow) {
                    show_app (((Widgets.PackageRow) row).get_package ());
                }
            });

            installed_flowbox.child_activated.connect ((child) => {
                if (child.get_child () is Widgets.InstalledPackageRowGrid) {
                    show_app (((Widgets.InstalledPackageRowGrid) child.get_child ()).package);
                }
            });

            update_all_button.clicked.connect (on_update_all);
        }

        private async void get_apps () {
            placeholder_stack.visible_child = loading_view;

            if (refresh_cancellable != null) {
                refresh_cancellable.cancel (); // Cancel any ongoing `get_installed_applications ()`
            }

            yield refresh_mutex.lock (); // Wait for any previous operation to end
            // We know refresh_cancellable is now null as it was set so before mutex was unlocked.
            refresh_cancellable = new Cancellable ();
            unowned var client = AppCenterCore.Client.get_default ();
            unowned var update_manager = AppCenterCore.UpdateManager.get_default ();
            if (client.updates_number > 0) {
                header_revealer.reveal_child = true;

                if (client.updates_number == update_manager.unpaid_apps_number || updating_all_apps) {
                    update_all_button.sensitive = false;
                } else {
                    update_all_button.sensitive = true;
                }

                header_label.label = ngettext (
                    "%u Update Available",
                    "%u Updates Available",
                    client.updates_number
                ).printf (client.updates_number);

                size_label.update (update_manager.updates_size, update_manager.has_flatpak_updates);
            } else {
                header_revealer.reveal_child = false;
            }

            var installed_apps = yield client.get_installed_applications (refresh_cancellable);

            if (!refresh_cancellable.is_cancelled ()) {
                clear ();

                var os_updates = AppCenterCore.UpdateManager.get_default ().os_updates;
                var os_updates_size = yield os_updates.get_download_size_including_deps ();
                if (os_updates_size > 0) {
                    add_row_for_package (os_updates);
                }

                var runtime_updates = AppCenterCore.UpdateManager.get_default ().runtime_updates;
                var runtime_updates_size = yield runtime_updates.get_download_size_including_deps ();
                if (runtime_updates_size > 0) {
                    add_row_for_package (runtime_updates);
                }

                add_packages (installed_apps);
            }

            yield client.get_prepared_applications (refresh_cancellable);

            refresh_cancellable = null;
            refresh_mutex.unlock ();

            if (update_manager.restart_required) {
                placeholder_stack.visible_child = restart_placeholder;
            } else {
                placeholder_stack.visible_child = updated_placeholder;
        		updated_placeholder.description = _("There are no updates available to install. Last checked %s.").printf (
                    Granite.DateTime.get_relative_datetime (
                        new DateTime.from_unix_local (AppCenter.App.settings.get_int64 ("last-refresh-time"))
                    )
        		);
            }
        }

        public void add_packages (Gee.Collection<AppCenterCore.Package> packages) {
            foreach (var package in packages) {
                add_row_for_package (package);
            }

            list_box.invalidate_sort ();
            installed_flowbox.invalidate_sort ();
        }

        private void add_row_for_package (AppCenterCore.Package package) {
            if (package.state == AppCenterCore.Package.State.UPDATE_AVAILABLE) {
                var row = new Widgets.PackageRow.installed (package, action_button_group);
                row.show_all ();

                list_box.add (row);
            } else if (package.kind != AppStream.ComponentKind.ADDON && package.kind != AppStream.ComponentKind.FONT) {
                var row = new Widgets.InstalledPackageRowGrid (package, action_button_group);
                row.show_all ();

                installed_flowbox.add (row);
            }
        }

        [CCode (instance_pos = -1)]
        private int package_row_compare (Widgets.PackageRow row1, Widgets.PackageRow row2) {
            var row1_package = row1.get_package ();
            var row2_package = row2.get_package ();

            bool a_is_driver = false;
            bool a_is_os = false;
            bool a_is_runtime = false;
            bool a_is_updating = false;
            string a_package_name = "";
            if (row1_package != null) {
                a_is_driver = row1_package.kind == AppStream.ComponentKind.DRIVER;
                a_is_os = row1_package.is_os_updates;
                a_is_runtime = row1_package.is_runtime_updates;
                a_is_updating = row1_package.is_updating;
                a_package_name = row1_package.get_name ();
            }

            bool b_is_driver = false;
            bool b_is_os = false;
            bool b_is_runtime = false;
            bool b_is_updating = false;
            string b_package_name = "";
            if (row2_package != null) {
                b_is_driver = row2_package.kind == AppStream.ComponentKind.DRIVER;
                b_is_os = row2_package.is_os_updates;
                b_is_runtime = row2_package.is_runtime_updates;
                b_is_updating = row2_package.is_updating;
                b_package_name = row2_package.get_name ();
            }

            // The currently updating package is always top of the list
            if (a_is_updating || b_is_updating) {
                return a_is_updating ? -1 : 1;
            }

            // Sort updatable OS updates first
            if (a_is_os || b_is_os) {
                return a_is_os ? -1 : 1;
            }

            if (a_is_driver != b_is_driver) {
                return a_is_driver ? - 1 : 1;
            }

            // Ensures runtime updates are sorted to the top amongst up-to-date packages but below OS updates
            if (a_is_runtime || b_is_runtime) {
                return a_is_runtime ? -1 : 1;
            }

            return a_package_name.collate (b_package_name); /* Else sort in name order */
        }

        [CCode (instance_pos = -1)]
        protected virtual int installed_sort_func (Gtk.FlowBoxChild child1, Gtk.FlowBoxChild child2) {
            var row1 = (Widgets.InstalledPackageRowGrid) child1.get_child ();
            var row2 = (Widgets.InstalledPackageRowGrid) child2.get_child ();

            return row1.package.get_name ().collate (row2.package.get_name ());
        }

        [CCode (instance_pos = -1)]
        private void row_update_header (Widgets.PackageRow row, Widgets.PackageRow? before) {
            bool is_driver = false;
            var row_package = row.get_package ();
            if (row_package != null) {
                is_driver = row_package.kind == AppStream.ComponentKind.DRIVER;
            }

            bool before_is_driver = false;
            if (before != null) {
                var before_package = before.get_package ();
                if (before_package != null) {
                    before_is_driver = before_package.kind == AppStream.ComponentKind.DRIVER;
                }
            }

            if (is_driver) {
                if (before != null && is_driver == before_is_driver) {
                    row.set_header (null);
                    return;
                }

                var header = new Granite.HeaderLabel (_("Drivers")) {
                    margin_top = 12,
                    margin_end = 9,
                    margin_start = 9
                };
                header.show_all ();
                row.set_header (header);
            } else {
                row.set_header (null);
            }
        }

        private void on_update_all () {
            perform_all_updates.begin ();
        }

        private async void perform_all_updates () {
            if (updating_all_apps) {
                return;
            }

            update_all_button.sensitive = false;
            updating_all_apps = true;

            foreach (unowned var child in list_box.get_children ()) {
                if (child is Widgets.PackageRow) {
                    ((Widgets.PackageRow) child).set_action_sensitive (false);

                    var package = ((Widgets.PackageRow) child).get_package ();
                    if (package.update_available && !package.should_pay) {
                        try {
                            yield package.update (false);
                        } catch (Error e) {
                            // If one package update was cancelled, drop out of the loop of updating the rest
                            if (e is GLib.IOError.CANCELLED) {
                                break;
                            } else {
                                var fail_dialog = new UpgradeFailDialog (package, e.message) {
                                    modal = true,
                                    transient_for = (Gtk.Window) get_toplevel ()
                                };
                                fail_dialog.present ();
                                break;
                            }
                        }
                    }
                }
            }

            unowned AppCenterCore.Client client = AppCenterCore.Client.get_default ();
            yield client.refresh_updates ();

            updating_all_apps = false;
        }

        public async void add_app (AppCenterCore.Package package) {
            unowned AppCenterCore.Client client = AppCenterCore.Client.get_default ();
            var installed_apps = yield client.get_installed_applications ();
            foreach (var app in installed_apps) {
                if (app == package) {
                    add_row_for_package (app);
                    list_box.invalidate_sort ();
                    installed_flowbox.invalidate_sort ();
                    break;
                }
            }
        }

        public async void remove_app (AppCenterCore.Package package) {
            foreach (unowned var child in list_box.get_children ()) {
                if (child is Widgets.PackageRow) {
                    unowned var row = (Widgets.PackageRow) child;

                    if (row.get_package () == package) {
                        row.destroy ();
                        list_box.invalidate_sort ();
                        return;
                    }
                }
            }

            foreach (unowned var child in installed_flowbox.get_children ()) {
                var row_child = ((Gtk.FlowBoxChild) child).get_child ();
                if (row_child is Widgets.InstalledPackageRowGrid) {
                    unowned var row = (Widgets.InstalledPackageRowGrid) row_child;

                    if (row.package == package) {
                        row.destroy ();
                        installed_flowbox.invalidate_sort ();
                        break;
                    }
                }
            }
        }

        public void clear () {
            foreach (unowned var child in list_box.get_children ()) {
                if (child is Widgets.PackageRow) {
                    child.destroy ();
                }
            };
            list_box.invalidate_sort ();

            foreach (unowned var child in installed_flowbox.get_children ()) {
                var row_child = ((Gtk.FlowBoxChild) child).get_child ();
                if (row_child is Widgets.InstalledPackageRowGrid) {
                    child.destroy ();
                }
            };
            installed_flowbox.invalidate_sort ();
        }
    }
}
