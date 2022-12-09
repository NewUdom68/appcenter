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

        private Granite.HeaderLabel header_label;
        private Gtk.Button back_button;
        private Gtk.Button update_all_button;
        private Gtk.ListBox list_box;
        private Gtk.Revealer header_revealer;
        private Gtk.SizeGroup action_button_group;
        private Widgets.SizeLabel size_label;
        private bool updating_all_apps = false;
        private Cancellable? refresh_cancellable = null;
        private AsyncMutex refresh_mutex = new AsyncMutex ();

        construct {
            var css_provider = new Gtk.CssProvider ();
            css_provider.load_from_resource ("io/elementary/appcenter/AppListUpdateView.css");

            back_button = new Gtk.Button.with_label (_("Home")) {
                action_name = "win.go-back",
                valign = Gtk.Align.CENTER
            };
            back_button.get_style_context ().add_class (Granite.STYLE_CLASS_BACK_BUTTON);

            var automatic_updates_button = new Granite.SwitchModelButton (_("Automatic App Updates")) {
                description = _("System updates and unpaid apps will not update automatically")
            };

            var refresh_accellabel = new Granite.AccelLabel.from_action_name (
                _("Check for Updates"),
                "app.refresh"
            );

            var refresh_menuitem = new Gtk.ModelButton () {
                action_name = "app.refresh"
            };
            refresh_menuitem.get_child ().destroy ();
            refresh_menuitem.add (refresh_accellabel);

            var menu_popover_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                margin_bottom = 6,
                margin_top = 6
            };
            menu_popover_box.add (automatic_updates_button);
            menu_popover_box.add (refresh_menuitem);
            menu_popover_box.show_all ();

            var menu_popover = new Gtk.Popover (null);
            menu_popover.add (menu_popover_box);

            var menu_button = new Gtk.MenuButton () {
                image = new Gtk.Image.from_icon_name ("open-menu", Gtk.IconSize.LARGE_TOOLBAR),
                popover = menu_popover,
                tooltip_text = _("Settings"),
                valign = Gtk.Align.CENTER
            };

            var headerbar = new Hdy.HeaderBar () {
                show_close_button = true
            };
            headerbar.pack_start (back_button);
            headerbar.pack_end (menu_button);

            var loading_view = new Granite.Widgets.AlertView (
                _("Checking for Updates"),
                _("Downloading a list of available updates to the OS and installed apps"),
                "sync-synchronizing"
            );
            loading_view.show_all ();

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
            list_box.set_placeholder (loading_view);

            var scrolled = new Gtk.ScrolledWindow (null, null) {
                hscrollbar_policy = Gtk.PolicyType.NEVER
            };
            scrolled.add (list_box);
            scrolled.get_style_context ().add_provider (css_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

            var info_label = new Gtk.Label (_("A restart is required to finish installing updates"));
            info_label.show ();

            var infobar = new Gtk.InfoBar ();
            infobar.message_type = Gtk.MessageType.WARNING;
            infobar.no_show_all = true;
            infobar.get_content_area ().add (info_label);

            var restart_button = infobar.add_button (_("Restart Now"), 0);

            action_button_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.BOTH);
            action_button_group.add_widget (update_all_button);
            action_button_group.add_widget (restart_button);

            infobar.response.connect ((response) => {
                if (response == 0) {
                    try {
                        SuspendControl.get_default ().reboot ();
                    } catch (GLib.Error e) {
                        if (!(e is IOError.CANCELLED)) {
                            info_label.label = _("Requesting a restart failed. Restart manually to finish installing updates");
                            infobar.message_type = Gtk.MessageType.ERROR;
                            restart_button.visible = false;
                        }
                    }
                }
            });

            AppCenterCore.UpdateManager.get_default ().bind_property ("restart-required", infobar, "visible", BindingFlags.SYNC_CREATE);

            orientation = Gtk.Orientation.VERTICAL;
            add (headerbar);
            add (infobar);
            add (header_revealer);
            add (scrolled);

            App.settings.bind (
                "automatic-updates",
                automatic_updates_button,
                "active",
                SettingsBindFlags.DEFAULT
            );

            get_apps.begin ();

            unowned var client = AppCenterCore.Client.get_default ();
            client.installed_apps_changed.connect (() => {
                Idle.add (() => {
                    get_apps.begin ();
                    return GLib.Source.REMOVE;
                });
            });

            automatic_updates_button.notify["active"].connect (() => {
                if (automatic_updates_button.active) {
                    client.update_cache.begin (true, AppCenterCore.Client.CacheUpdateType.FLATPAK);
                } else {
                    client.cancel_updates (true);
                }
            });

            realize.connect (label_back_button);

            list_box.row_activated.connect ((row) => {
                if (row is Widgets.PackageRow) {
                    show_app (((Widgets.PackageRow) row).get_package ());
                }
            });

            update_all_button.clicked.connect (on_update_all);
        }

        private void label_back_button () {
            var deck = (Hdy.Deck) get_ancestor (typeof (Hdy.Deck));

            deck.notify["transition-running"].connect (() => {
                if (!deck.transition_running) {
                    var previous_child = deck.get_adjacent_child (Hdy.NavigationDirection.BACK);

                    if (previous_child is Homepage) {
                        back_button.label = _("Home");
                    } else if (previous_child is SearchView) {
                        /// TRANSLATORS: the name of the Search view
                        back_button.label = C_("view", "Search");
                    } else if (previous_child is Views.AppInfoView) {
                        back_button.label = ((Views.AppInfoView) previous_child).package.get_name ();
                    } else if (previous_child is CategoryView) {
                        back_button.label = ((CategoryView) previous_child).category.name;
                    } else if (previous_child is Views.AppListUpdateView) {
                        back_button.label = C_("view", "Installed");
                    }
                }
            });
        }

        private async void get_apps () {
            if (refresh_cancellable != null) {
                refresh_cancellable.cancel (); // Cancel any ongoing `get_installed_applications ()`
            }

            yield refresh_mutex.lock (); // Wait for any previous operation to end
            // We know refresh_cancellable is now null as it was set so before mutex was unlocked.
            refresh_cancellable = new Cancellable ();
            unowned var client = AppCenterCore.Client.get_default ();
            if (client.updates_number > 0) {
                header_revealer.reveal_child = true;

                unowned var update_manager = AppCenterCore.UpdateManager.get_default ();
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
                add_package (os_updates);
                add_packages (installed_apps);
            }

            refresh_cancellable = null;
            refresh_mutex.unlock ();
        }

        public void add_packages (Gee.Collection<AppCenterCore.Package> packages) {
            foreach (var package in packages) {
                add_row_for_package (package);
            }

            list_box.invalidate_sort ();
        }

        public void add_package (AppCenterCore.Package package) {
            add_row_for_package (package);
            list_box.invalidate_sort ();
        }

        private void add_row_for_package (AppCenterCore.Package package) {
            var needs_update = package.state == AppCenterCore.Package.State.UPDATE_AVAILABLE;

            // Only add row if this package needs an update or it's not a font or plugin
            if (needs_update || (package.kind != AppStream.ComponentKind.ADDON && package.kind != AppStream.ComponentKind.FONT)) {
                var row = new Widgets.PackageRow.installed (package, action_button_group);
                row.show_all ();

                list_box.add (row);
            }
        }

        [CCode (instance_pos = -1)]
        private int package_row_compare (Widgets.PackageRow row1, Widgets.PackageRow row2) {
            var row1_package = row1.get_package ();
            var row2_package = row2.get_package ();

            bool a_has_updates = false;
            bool a_is_driver = false;
            bool a_is_os = false;
            bool a_is_updating = false;
            string a_package_name = "";
            if (row1_package != null) {
                a_has_updates = row1_package.update_available;
                a_is_driver = row1_package.kind == AppStream.ComponentKind.DRIVER;
                a_is_os = row1_package.is_os_updates;
                a_is_updating = row1_package.is_updating;
                a_package_name = row1_package.get_name ();
            }

            bool b_has_updates = false;
            bool b_is_driver = false;
            bool b_is_os = false;
            bool b_is_updating = false;
            string b_package_name = "";
            if (row2_package != null) {
                b_has_updates = row2_package.update_available;
                b_is_driver = row2_package.kind == AppStream.ComponentKind.DRIVER;
                b_is_os = row2_package.is_os_updates;
                b_is_updating = row2_package.is_updating;
                b_package_name = row2_package.get_name ();
            }

            // The currently updating package is always top of the list
            if (a_is_updating || b_is_updating) {
                return a_is_updating ? -1 : 1;
            }

            // Sort updatable OS updates first, then other updatable packages
            if (a_has_updates != b_has_updates) {
                if (a_is_os && a_has_updates) {
                    return -1;
                }

                if (b_is_os && b_has_updates) {
                    return 1;
                }

                if (a_has_updates) {
                    return -1;
                }

                if (b_has_updates) {
                    return 1;
                }
            }

            if (a_is_driver != b_is_driver) {
                return a_is_driver ? - 1 : 1;
            }

            // Ensures OS updates are sorted to the top amongst up-to-date packages
            if (a_is_os || b_is_os) {
                return a_is_os ? -1 : 1;
            }

            return a_package_name.collate (b_package_name); /* Else sort in name order */
        }

        [CCode (instance_pos = -1)]
        private void row_update_header (Widgets.PackageRow row, Widgets.PackageRow? before) {
            bool update_available = false;
            bool is_driver = false;
            var row_package = row.get_package ();
            if (row_package != null) {
                update_available = row_package.update_available || row_package.is_updating;
                is_driver = row_package.kind == AppStream.ComponentKind.DRIVER;
            }


            bool before_update_available = false;
            bool before_is_driver = false;
            if (before != null) {
                var before_package = before.get_package ();
                if (before_package != null) {
                    before_update_available = before_package.update_available || before_package.is_updating;
                    before_is_driver = before_package.kind == AppStream.ComponentKind.DRIVER;
                }
            }

            if (update_available) {
                if (before != null && update_available == before_update_available) {
                    row.set_header (null);
                    return;
                }
            } else if (is_driver) {
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
                if (before != null && is_driver == before_is_driver && update_available == before_update_available) {
                    row.set_header (null);
                    return;
                }

                var header = new Granite.HeaderLabel (_("Up to Date")) {
                    margin_top = 12,
                    margin_end = 9,
                    margin_start = 9
                };
                header.show_all ();
                row.set_header (header);
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
                    add_package (app);
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
                        break;
                    }
                }
            }

            list_box.invalidate_sort ();
        }

        public void clear () {
            foreach (unowned var child in list_box.get_children ()) {
                if (child is Widgets.PackageRow) {
                    child.destroy ();
                }
            };

            list_box.invalidate_sort ();
        }
    }
}
