;;; ebasecamp.el --- Emacs 中的 Docker 环境分组管理 -*- lexical-binding: t; -*-

;; Author: Thomas
;; Version: 0.5.2
;; Keywords: tools, convenience
;; Package-Requires: ((emacs "29.1") (etaf "0.2.3") (etaf-ui "0.1.3"))

;;; Commentary:

;; ebasecamp 把 Docker 环境按「组 → 配置 → 项目」组织：
;;
;; - 组（group）是可复用的基础组件集合，例如 mysql、redis，是全局第一等
;;   对象，不依赖任何项目即可存在；scope 为 shared（跨项目共用一套容器）
;;   或 per-project（每个项目一套）；
;; - 配置（config）挂在组的 `:configs' 槽里，用 `:project' 指向一个项目，
;;   并可为该项目覆盖端口、环境变量与卷；一份配置 = 一个「组 × 项目」实例；
;; - 项目（project）是业务工程的容器，提供 title / root / shared-network /
;;   export-file；项目对组的引用由组内 `:configs' 在加载期物化而来。
;;
;; 主界面以组为中心：左栏「组 → 配置」树，右栏每份配置一段服务表，勾选
;; 服务后按段批量启动/停止/重启。
;;
;; 清单目录：默认为 `ebasecamp-config-directory'（~/.config/ebasecamp/），
;; 结构如下：
;;
;;   <dir>/groups.el        服务组定义
;;   <dir>/projects/*.el    项目定义（按文件名字典序加载）
;;
;; 清单是唯一事实源；compose 文件是派生生成物，位于
;; `ebasecamp-cache-directory'（~/.cache/ebasecamp/<project>/compose.yaml），
;; 可随时重建，不要手工编辑。
;;
;; 常用命令：
;;
;;   M-x ebasecamp                      打开管理界面（组 → 配置 → 项目）
;;   M-x ebasecamp-reload               重新加载清单并刷新界面
;;   M-x ebasecamp-create-sample-config 生成示例清单（C-u 前缀强制覆盖）
;;   M-x ebasecamp-import-file          从 compose 文件导入清单
;;   M-x ebasecamp-export-compose       选项目导出为部署用 compose
;;   M-x ebasecamp-ui-close             关闭主界面，停轮询并销毁会话
;;
;; 界面内的导入 / 导出 / 销毁环境走底栏三个按钮
;; （`ebasecamp-ui-import-compose' / `ebasecamp-ui-export-compose' /
;; `ebasecamp-ui-destroy-environment'）。
;;
;; 安全约束：
;;
;; - 清单只保存 ${VAR} 引用与相对路径，绝不落盘密钥明文；
;; - 插件不读取、不打印任何密钥值，docker 侧由 compose 在运行时插值；
;; - 读取项目 compose 只用 `docker compose config --no-interpolate'
;;   系列 flag，避免密钥被展开。

;;; Code:

(defgroup ebasecamp nil
  "Emacs 中的 Docker 环境分组管理。"
  :group 'tools
  :prefix "ebasecamp-")

(require 'ebasecamp-model)
(require 'ebasecamp-config)
(require 'ebasecamp-compose)
(require 'ebasecamp-docker)
(require 'ebasecamp-import)
(require 'ebasecamp-export)
(require 'ebasecamp-status)
(require 'ebasecamp-data)
(require 'ebasecamp-ui)

;;; 示例清单生成

(defun ebasecamp--sample-groups-source ()
  "返回示例 `groups.el' 的文件内容。
首行带文件局部变量，避免加载时出现 lexical-binding 警告；凭据只用
${VAR} 引用，不含任何明文。"
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; groups.el --- ebasecamp 示例服务组\n"
   "\n"
   ";; 由 M-x ebasecamp-create-sample-config 生成，可以自由修改。\n"
   ";; 安全约定：只保存 ${VAR} 引用，不要把密钥明文写进清单。\n"
   "\n"
   "(ebasecamp-define-group mysql\n"
   "  :title \"MySQL\"\n"
   "  :scope shared\n"
   "  :services\n"
   "  ((mysql :image \"mysql:8.4\"\n"
   "          :ports ((3306 . 3306))\n"
   "          :environment ((\"MYSQL_ROOT_PASSWORD\"\n"
   "                         . \"${EBASECAMP_MYSQL_ROOT_PASSWORD}\")))))\n"
   "\n"
   "(ebasecamp-define-group redis\n"
   "  :title \"Redis\"\n"
   "  :scope per-project\n"
   "  :services\n"
   "  ((redis :image \"redis:7\"\n"
   "          :ports ((6379 . 6379)))))\n"))

(defun ebasecamp--sample-project-source ()
  "返回示例 `projects/example.el' 的文件内容。"
  (concat
   ";;; -*- lexical-binding: t; -*-\n"
   ";;; example.el --- ebasecamp 示例项目\n"
   "\n"
   ";; 由 M-x ebasecamp-create-sample-config 生成，可以自由修改。\n"
   "\n"
   "(ebasecamp-define-project example\n"
   "  :title \"示例项目\"\n"
   "  :root \"~/Workspace/example\"\n"
   "  :groups ((mysql)\n"
   "           (redis)))\n"))

(defun ebasecamp--write-file (path content)
  "把字符串 CONTENT 写入 PATH，父目录不存在时一并创建。返回 PATH。"
  (make-directory (file-name-directory path) t)
  (with-temp-file path (insert content))
  path)

(defun ebasecamp--manifest-files (directory)
  "返回 DIRECTORY 下已有的清单文件列表。
包含 `groups.el'（存在时）与 `projects/' 下的 *.el（按文件名字典序）。"
  (let ((groups (expand-file-name "groups.el" directory)))
    (append (and (file-regular-p groups) (list groups))
            (ebasecamp-config--project-files directory))))

;;;###autoload
(defun ebasecamp ()
  "打开 ebasecamp 管理界面（左栏「组 → 配置」树，右栏按配置分段）。
打开后用 `message' 报告组数 / 配置数（有旧写法关联时附其数量）—— 回执让
「组树为空壳」与「命令失灵」可区分。返回界面 buffer。"
  (interactive)
  (prog1 (ebasecamp-ui-open)
    (ebasecamp-ui-report-counts)))

;;;###autoload
(defun ebasecamp-create-sample-config (&optional force)
  "在 `ebasecamp-config-directory' 下生成示例清单。
生成 `groups.el'（mysql / redis 两个组）与 `projects/example.el'
（示例项目），两个文件都带 lexical-binding 首行。

清单已存在（`groups.el' 或 `projects/*.el' 任一存在）且 FORCE 为 nil 时
以 `user-error' 拒绝执行，避免覆盖用户的手写定义；交互式调用时用
\\[universal-argument] 前缀（C-u）强制覆盖。返回生成的 `groups.el'
绝对路径。"
  (interactive "P")
  (let* ((directory (ebasecamp-config-ensure-directory))
         (groups-file (expand-file-name "groups.el" directory))
         (project-file (ebasecamp-config-project-file "example" directory)))
    (when (and (not force) (ebasecamp--manifest-files directory))
      (user-error
       "清单已存在于 %s；用 C-u M-x ebasecamp-create-sample-config 强制覆盖"
       directory))
    (ebasecamp--write-file groups-file (ebasecamp--sample-groups-source))
    (ebasecamp--write-file project-file (ebasecamp--sample-project-source))
    (when (called-interactively-p 'interactive)
      (message "已生成示例清单 %s；可先编辑它，再 M-x ebasecamp 打开界面"
               groups-file))
    groups-file))

;;;###autoload
(defun ebasecamp-reload ()
  "重新加载清单并刷新界面。
返回 `ebasecamp-config-load' 的结果 plist；界面 buffer 存在时顺带刷新
表格数据，并用 `message' 报告组/项目/错误数量。"
  (interactive)
  (let* ((result (ebasecamp-config-load))
         (groups (length (plist-get result :groups)))
         (projects (length (plist-get result :projects)))
         (errors (length (plist-get result :errors))))
    (when (get-buffer ebasecamp-ui-buffer-name)
      (ebasecamp-ui-refresh))
    (message "ebasecamp：已加载 %d 个组、%d 个项目%s"
             groups projects
             (if (zerop errors)
                 ""
               (format "，%d 个错误（见 %s）" errors
                       ebasecamp-config-directory)))
    result))

(provide 'ebasecamp)
;;; ebasecamp.el ends here
