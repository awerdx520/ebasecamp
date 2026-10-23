;;; ebasecamp-config.el --- ebasecamp 清单加载 -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.4.0
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; 清单加载层：把磁盘上的 Elisp 清单读进 ebasecamp-model 的注册表。
;;
;; 目录结构：
;;   <dir>/groups.el        服务组定义（可选）
;;   <dir>/projects/*.el    项目定义，按文件名字典序加载（目录本身可选）
;;
;; 加载语义：
;; - 每次加载先清空注册表，重新加载是幂等的，不累积旧定义；
;; - 目录不存在时不创建目录，返回 :bootstrap-needed t，由
;;   `ebasecamp-create-sample-config' 负责生成示例清单；
;; - 单个文件出错（语法错、未知关键字、重复组名等）只记入 :errors，
;;   不中断后续文件；
;; - 模型注册表只支持追加，所以某文件加载失败时用「重置 + 重放已成功
;;   文件」回滚，保证失败文件的定义不会残留在清单中；
;; - 全部加载后校验项目的组引用（未定义组、同组重复引用），引用未定义组
;;   或重复引用时追加错误；
;; - 最后进入物化阶段 `ebasecamp-model-link-configs`，把组内 :configs 并入
;;   项目的 groups 槽，物化错误同样记入 :errors（定义期错误的条目在前，
;;   物化期在后）。
;;
;; 错误项结构：(:file PATH :condition CONDITION-DATA :message STRING)。
;; :file 为定义所在文件的绝对路径，无法定位时为 nil；物化阶段的错误由本层
;; 统一补填为 groups.el 的绝对路径（配置只能定义在 groups.el）。:message 是
;; 人类可读描述，便于界面直接展示。
;;
;; 本文件不读取、不插值、不落盘任何密钥值。

;;; Code:

(require 'cl-lib)
(require 'ebasecamp-model)

(define-error 'ebasecamp-config-error "Invalid ebasecamp config")
(define-error 'ebasecamp-config-missing-group
  "Project references an undefined group"
  'ebasecamp-config-error)
(define-error 'ebasecamp-config-duplicate-group-ref
  "Project references the same group more than once"
  'ebasecamp-config-error)

(defcustom ebasecamp-config-directory (expand-file-name "~/.config/ebasecamp/")
  "ebasecamp 清单所在目录。
该目录下 `groups.el' 定义服务组，`projects/' 下的 *.el 定义项目。
目录不存在时加载不会自动创建，见 `ebasecamp-config-ensure-directory'。"
  :type 'directory
  :group 'ebasecamp)

;;; 路径助手

(defun ebasecamp-config--directory (&optional directory)
  "返回清单目录的绝对路径，以目录分隔符结尾。
DIRECTORY 省略时使用 `ebasecamp-config-directory'。"
  (file-name-as-directory
   (expand-file-name (or directory ebasecamp-config-directory))))

(defun ebasecamp-config-project-file (name &optional directory)
  "返回项目 NAME 的清单文件绝对路径。
路径形如 <DIRECTORY>/projects/<NAME>.el；NAME 可以是 symbol 或字符串，
DIRECTORY 省略时使用 `ebasecamp-config-directory'。文件是否存在不做检查。"
  (expand-file-name
   (concat "projects/"
           (if (stringp name) name (symbol-name name))
           ".el")
   (ebasecamp-config--directory directory)))

(defun ebasecamp-config-ensure-directory (&optional directory)
  "创建清单目录并返回其绝对路径（以目录分隔符结尾）。
DIRECTORY 省略时使用 `ebasecamp-config-directory'；父目录不存在时一并创建，
目录已存在时不做任何改动。供 `ebasecamp-create-sample-config' 使用。"
  (let ((dir (ebasecamp-config--directory directory)))
    (make-directory dir t)
    dir))

;;; 文件枚举

(defun ebasecamp-config--project-files (&optional directory)
  "返回清单目录 `projects/' 下所有 .el 文件的绝对路径列表。
按文件名字典序排列，忽略子目录与非 .el 文件；`projects/' 不存在时返回 nil。"
  (let ((projects (expand-file-name "projects/"
                                    (ebasecamp-config--directory directory))))
    (when (file-directory-p projects)
      (sort (cl-remove-if-not #'file-regular-p
                              (directory-files projects t "\\.el\\'"))
            #'string<))))

(defun ebasecamp-config--files (directory)
  "返回 DIRECTORY 下按加载顺序排列的清单文件列表。
`groups.el' 排在 `projects/*.el' 之前；不存在的文件不出现在列表中。"
  (let ((groups (expand-file-name "groups.el" directory)))
    (append (and (file-regular-p groups) (list groups))
            (ebasecamp-config--project-files directory))))

;;; 单文件加载

(defun ebasecamp-config--project-names ()
  "返回当前注册表中的全部项目名。"
  (mapcar #'ebasecamp-project-name (ebasecamp-model-projects)))

(defun ebasecamp-config--load-file (file origins)
  "加载清单文件 FILE，并把新注册的项目记入 ORIGINS。
ORIGINS 是 hash 表（项目名 -> 定义所在文件路径）。加载成功返回 nil；
出错时捕获条件并返回错误 plist，形如
\(:file PATH :condition CONDITION-DATA :message STRING)。
文件已产生的部分定义由调用方回滚。"
  (let ((known (ebasecamp-config--project-names)))
    (condition-case err
        (progn
          (load file nil t)
          (dolist (name (ebasecamp-config--project-names))
            (unless (memq name known)
              (puthash name file origins)))
          nil)
      (error
       (list :file file
             :condition err
             :message (error-message-string err))))))

(defun ebasecamp-config--reload (files origins)
  "清空注册表后按顺序重新加载 FILES，并刷新 ORIGINS 中的项目归属。
用于某个文件加载失败后的回滚：模型注册表只支持追加，因此只能通过重放
已成功的文件来丢弃失败文件留下的定义。"
  (ebasecamp-model-reset)
  (dolist (file files)
    (ebasecamp-config--load-file file origins)))

;;; 引用校验

(defun ebasecamp-config--validate-projects (origins)
  "校验每个项目的组引用，返回错误 plist 列表。
两类错误依次排列：先「引用了未定义的组」，后「同一项目重复引用同一组」
（D2：同一项目 + 同一组只允许 1 个引用，容器标签无配置维度，服务名会撞）。
ORIGINS 为项目名到定义文件的 hash 表；项目无法定位到文件时 :file 为 nil，
message 中仍包含项目名与组名。错误按项目与组引用的顺序排列。"
  (let ((errors nil)
        (duplicates nil))
    (dolist (project (ebasecamp-model-projects))
      (let ((project-name (ebasecamp-project-name project))
            (file (gethash (ebasecamp-project-name project) origins)))
        (dolist (reference (ebasecamp-project-groups project))
          (let ((group-name (plist-get reference :group)))
            (unless (ebasecamp-model-group group-name)
              (push (list :file file
                          :condition (list 'ebasecamp-config-missing-group
                                           project-name group-name file)
                          :message (format "项目 %s（%s）引用了未定义的组 %s"
                                           project-name
                                           (or file "定义文件未知")
                                           group-name))
                    errors))))))
    (setq errors (nreverse errors))
    (dolist (project (ebasecamp-model-projects))
      (let ((project-name (ebasecamp-project-name project))
            (file (gethash (ebasecamp-project-name project) origins))
            (seen nil))
        (dolist (reference (ebasecamp-project-groups project))
          (let ((group-name (plist-get reference :group)))
            (if (memq group-name seen)
                (push (list :file file
                            :condition
                            (list 'ebasecamp-config-duplicate-group-ref
                                  project-name group-name file)
                            :message (format "项目 %s（%s）重复引用组 %s"
                                             project-name
                                             (or file "定义文件未知")
                                             group-name))
                      duplicates)
              (push group-name seen))))))
    (append errors (nreverse duplicates))))

;;; 加载期物化

(defun ebasecamp-config--link-configs (directory)
  "物化组内配置，并把错误项的 :file 补填为 <DIRECTORY>/groups.el。
`ebasecamp-model-link-configs' 只在 :condition 里携带
\(CODE . (组名 . 项目名)) 上下文（模型层不感知文件），而配置定义只能写在
groups.el，因此这里统一把 :file 指向该文件的绝对路径，不留 nil。返回补填后
的错误列表；模型层的部分成功语义保持不变（成功物化的配置仍生效）。"
  (let ((groups-file (expand-file-name "groups.el" directory)))
    (mapcar (lambda (error)
              (plist-put error :file groups-file))
            (ebasecamp-model-link-configs))))

;;; 加载入口

(defun ebasecamp-config-load (&optional directory)
  "加载 ebasecamp 清单并返回状态 plist。
DIRECTORY 省略时使用 `ebasecamp-config-directory'。返回值固定为
  (:groups GROUPS :projects PROJECTS :errors ERRORS :bootstrap-needed BOOL)
GROUPS 与 PROJECTS 是本次加载后的注册表内容；ERRORS 是错误 plist 列表，
每项形如 (:file PATH :condition CONDITION-DATA :message STRING)，按发生顺序
排列；BOOL 在目录不存在时为 t，此时不创建目录、ERRORS 为空。

加载顺序（任一步出错都只记错误、不中断后续步骤）：
1. 清空注册表（重新加载幂等）；
2. 依次加载 `groups.el' 与 `projects/' 下的 *.el（按文件名字典序），单文件
   出错时记录错误、丢弃该文件已产生的定义并按重放回滚；
3. 校验项目对组的引用（未定义组、同组重复引用）；
4. 物化组内 :configs 到项目 groups 槽（`ebasecamp-model-link-configs'），
   错误的 :file 补填为 groups.el。

错误顺序为「文件加载 → 项目引用校验 → 物化」，即定义期在前、物化期在后。
物化阶段的部分成功语义：出错的配置只记错误，其余配置照常物化并生效。"
  (let* ((dir (ebasecamp-config--directory directory))
         (origins (make-hash-table :test #'eq))
         (loaded nil)
         (errors nil)
         (bootstrap-needed (not (file-directory-p dir))))
    (ebasecamp-model-reset)
    (unless bootstrap-needed
      (dolist (file (ebasecamp-config--files dir))
        (let ((error (ebasecamp-config--load-file file origins)))
          (if error
              (progn
                (push error errors)
                (ebasecamp-config--reload (reverse loaded) origins))
            (push file loaded))))
      (setq errors (nreverse errors))
      ;; 定义期校验：项目对组的引用（未定义组 / 同组重复引用）
      (setq errors (append errors (ebasecamp-config--validate-projects origins)))
      ;; 物化期：组内配置并入项目 groups 槽（错误的 :file 由本层补填）
      (setq errors (append errors (ebasecamp-config--link-configs dir))))
    (list :groups (ebasecamp-model-groups)
          :projects (ebasecamp-model-projects)
          :errors errors
          :bootstrap-needed bootstrap-needed)))

(provide 'ebasecamp-config)
;;; ebasecamp-config.el ends here
