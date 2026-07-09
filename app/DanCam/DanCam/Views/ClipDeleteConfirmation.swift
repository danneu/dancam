import UIKit

enum ClipDeleteConfirmation {
    static func alert(confirm: @escaping () -> Void, cancel: (() -> Void)? = nil) -> UIAlertController {
        let alert = UIAlertController(
            title: "Delete clip?",
            message: "This removes the clip from the camera unit.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            cancel?()
        })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            confirm()
        })
        return alert
    }

    static func swipeAction(
        presenting presenter: UIViewController,
        confirm: @escaping () -> Void
    ) -> UIContextualAction {
        let action = UIContextualAction(style: .destructive, title: "Delete") { [weak presenter] _, _, completion in
            guard let presenter else {
                completion(false)
                return
            }

            presenter.present(
                alert(
                    confirm: {
                        confirm()
                        completion(true)
                    },
                    cancel: {
                        completion(false)
                    }
                ),
                animated: true
            )
        }
        action.image = UIImage(systemName: "trash")
        return action
    }
}
